#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# audit-worktree-removal-helper.sh — Canonical audit logger for worktree-removal events (t2976).
#
# Every worktree removal event — taken or skipped — should leave exactly one structured
# log line in cleanup_worktrees.log. This helper centralises that write so callers
# never need to construct the format themselves.
#
# Usage (source this file, then call the function):
#   # shellcheck source=audit-worktree-removal-helper.sh
#   source "${SCRIPT_DIR}/audit-worktree-removal-helper.sh"
#   log_worktree_removal_event "$_WTAR_REMOVED" "worktree-helper.sh" "/path/to/wt" "branch-merged" "permanent"
#   log_worktree_removal_event "$_WTAR_SKIPPED" "pulse-cleanup.sh" "/path/to/wt" "owned-skip" "skipped" \
#     "branch=feature/gh123 issue=123 owner_guard=active pr_state=none recovery_path=none"
#
# Event types (use the constants below to avoid repeated literal violations):
#   _WTAR_REMOVED          "removed"        — worktree was actually removed
#   _WTAR_SKIPPED          "skipped"        — removal was blocked
#   _WTAR_FIXTURE_REMOVED  "fixture-removed" — removed during test teardown
#
# Reason values (non-exhaustive — free-form, kept short):
#   branch-merged     — PR/branch has merged; worktree no longer needed
#   age-eligible      — orphan exceeded age threshold (crashed/abandoned worker)
#   manual            — operator called remove directly
#   owned-skip        — owned by another active session (registry or pgrep match)
#   grace-period      — within WORKTREE_CLEAN_GRACE_HOURS, not safe to remove yet
#   open-pr           — branch has an open PR; active work in progress
#   zero-commit-dirty — 0 commits ahead + dirty files = in-progress, not merged
#   empty-branch      — 0 commits ahead = pre-work branch (t3545/GH#22606)
#   active-claim      — interactive-session claim stamp present (t2916/GH#21074)
#   current-worktree  — caller is inside this worktree (GH#22154)
#   dirty-skip        — uncommitted changes present, --force-merged not set
#   fixture           — test fixture teardown path
#
# Environment:
#   AIDEVOPS_CLEANUP_LOG — override log file path (default: ~/.aidevops/logs/cleanup_worktrees.log)
#
# Compatibility: bash 3.2+ (macOS default). Uses printf, not echo -e.
# Fail-open: log write failures are silently swallowed — callers must not depend on
# this helper succeeding for their own logic.

# Guard against double-sourcing
[[ "${_AUDIT_WORKTREE_REMOVAL_HELPER_LOADED:-}" == "1" ]] && return 0
_AUDIT_WORKTREE_REMOVAL_HELPER_LOADED=1

# =============================================================================
# Event-type constants — callers should use these instead of inline string
# literals to stay below the pre-commit repeated-literal ratchet threshold.
# =============================================================================
_WTAR_REMOVED="removed"
_WTAR_SKIPPED="skipped"
_WTAR_FIXTURE_REMOVED="fixture-removed"
_WTAR_MODE_SKIPPED="skipped"
_WTAR_BOOL_TRUE="true"
_WT_CWD_VISIBILITY_COMPLETE="complete"
_WT_CWD_VISIBILITY_DEGRADED="degraded"
_WT_CWD_VISIBILITY_UNUSABLE="unusable"
_WT_CWD_CAPTURE_DEGRADED_RC=2
_WT_CWD_MATCH_UNUSABLE_RC=3
_WT_CWD_REASON_DEGRADED="cwd-visibility-degraded"
_WT_CWD_REASON_UNUSABLE="cwd-visibility-unusable"
_WT_GIT_STATE_CLEAR="clear"
_WT_GIT_STATE_LOCKED="locked"
_WT_GIT_STATE_NOT_WORKTREE="not-worktree"
_WT_GIT_STATE_UNREADABLE="unreadable"
_WT_GIT_REASON_LOCKED="git-worktree-locked"
_WT_GIT_REASON_UNREADABLE="git-metadata-unreadable"
_WT_GIT_REASON_IDENTITY_CHANGED="git-worktree-identity-changed"
_WT_GIT_REASON_REMOVE_FAILED="git-worktree-remove-failed"
_WT_GIT_STATUS_FIELD_PREFIX="aidevops-git-status "
_WT_RECOVERY_FORMAT="aidevops-worktree-recovery-v1"
_WT_RECOVERY_DIR_NAME=".aidevops-worktree-recovery"
_WT_RECOVERY_BRANCH_DETACHED="detached"
WORKTREE_RECOVERABLE_ARCHIVE_PATH=""

_WT_ID_REAL_GIT=""
_WT_ID_SOURCE_REAL=""
_WT_ID_SOURCE_INODE=""
_WT_ID_ADMIN_REAL=""
_WT_ID_ADMIN_INODE=""
_WT_ID_COMMON_REAL=""
_WT_ID_HEAD=""
_WT_ID_BRANCH=""

# =============================================================================
# log_worktree_removal_event — write one structured log line per event
#
# Args:
#   $1  event_type  — use $_WTAR_REMOVED / $_WTAR_SKIPPED / $_WTAR_FIXTURE_REMOVED
#   $2  caller      — basename of the calling script (e.g. "worktree-helper.sh")
#   $3  wt_path     — absolute path to the worktree
#   $4  reason      — short reason string (see Reason values above)
#   $5  mode        — optional removal mode: trash, permanent, fixture, skipped
#   $6  context     — optional safe key=value context for guard predicates/recovery
#
# Output format (append to AIDEVOPS_CLEANUP_LOG):
#   [2026-04-27T11:22:33Z] [worktree-helper.sh] worktree-removed: /path/to/wt — branch-merged — mode=permanent
#   [2026-05-07T12:00:00Z] [pulse-cleanup.sh] worktree-skipped: /path/to/wt — owned-skip — mode=skipped — branch=feature/gh123 issue=123 owner_guard=active
#
# Returns 0 always (fail-open).
# =============================================================================
log_worktree_removal_event() {
	local event_type="$1"
	local caller="$2"
	local wt_path="$3"
	local reason="$4"
	local mode="${5:-unknown}"
	local context="${6:-}"
	local log_file="${AIDEVOPS_CLEANUP_LOG:-${HOME}/.aidevops/logs/cleanup_worktrees.log}"

	# Ensure log directory exists (silent; don't fail callers on permission errors)
	mkdir -p "$(dirname "$log_file")" 2>/dev/null || true

	# Write one structured line and swallow any write error (fail-open)
	if [[ -n "$context" ]]; then
		printf '[%s] [%s] worktree-%s: %s — %s — mode=%s — %s\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			"$caller" \
			"$event_type" \
			"$wt_path" \
			"$reason" \
			"$mode" \
			"$context" \
			>>"$log_file" 2>/dev/null || true
	else
		printf '[%s] [%s] worktree-%s: %s — %s — mode=%s\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			"$caller" \
			"$event_type" \
			"$wt_path" \
			"$reason" \
			"$mode" \
			>>"$log_file" 2>/dev/null || true
	fi

	return 0
}

_worktree_proc_entry_is_provably_foreign_uid() {
	local proc_dir="$1"
	local current_uid="$2"
	local field=""
	local real_uid=""
	local effective_uid=""
	local saved_uid=""
	local filesystem_uid=""
	local process_uid=""

	[[ "$current_uid" =~ ^[0-9]+$ && -r "$proc_dir/status" ]] || return 1
	while IFS=$' \t' read -r field real_uid effective_uid saved_uid filesystem_uid _; do
		[[ "$field" == "Uid:" ]] || continue
		for process_uid in "$real_uid" "$effective_uid" "$saved_uid" "$filesystem_uid"; do
			[[ "$process_uid" =~ ^[0-9]+$ ]] || return 1
			[[ "$process_uid" != "$current_uid" ]] || return 1
		done
		return 0
	done <"$proc_dir/status"
	return 1
}

_capture_worktree_proc_cwds() {
	local proc_root="$1"
	local cwd_link=""
	local cwd_target=""
	local captured_count=0
	local current_uid=""
	local visibility_degraded=0
	local proc_dir=""

	current_uid=$(id -u 2>/dev/null) || current_uid=""

	for cwd_link in "$proc_root"/[0-9]*/cwd; do
		[[ -L "$cwd_link" || -e "$cwd_link" ]] || continue
		if ! cwd_target=$(readlink "$cwd_link" 2>/dev/null); then
			# Vanished processes are harmless. Linux commonly denies cwd reads for
			# other users, so skip only entries whose four status UIDs prove they
			# are foreign. Persistent same-user or unknown-ownership denials make
			# visibility degraded without discarding readable cwd evidence.
			[[ -L "$cwd_link" || -e "$cwd_link" ]] || continue
			proc_dir="${cwd_link%/cwd}"
			_worktree_proc_entry_is_provably_foreign_uid "$proc_dir" "$current_uid" && continue
			visibility_degraded=1
			continue
		fi
		if [[ -n "$cwd_target" ]]; then
			printf '%s\n' "$cwd_target"
			captured_count=$((captured_count + 1))
		fi
	done
	if [[ "$visibility_degraded" -eq 1 ]]; then
		return "$_WT_CWD_CAPTURE_DEGRADED_RC"
	fi
	[[ "$captured_count" -gt 0 ]] || return 1
	return 0
}

_capture_worktree_lsof_cwds() {
	local cwd_target=""
	local captured_count=0
	local lsof_line=""
	local lsof_output=""
	local lsof_status=0

	if lsof_output=$(lsof -n -F n -d cwd 2>/dev/null); then
		lsof_status=0
	else
		lsof_status=$?
	fi
	while IFS= read -r lsof_line; do
		case "$lsof_line" in
		n*)
			cwd_target="${lsof_line#n}"
			if [[ -n "$cwd_target" ]]; then
				printf '%s\n' "$cwd_target"
				captured_count=$((captured_count + 1))
			fi
			;;
		esac
	done <<<"$lsof_output"
	[[ "$captured_count" -gt 0 ]] || return 1
	if [[ "$lsof_status" -ne 0 ]]; then
		return "$_WT_CWD_CAPTURE_DEGRADED_RC"
	fi
	return 0
}

# Capture every visible live-process cwd. stdout always preserves readable
# targets. Return 0 for complete visibility, 2 for degraded visibility with
# same-UID/unknown denials, and 1 when no usable snapshot can be established.
# Callers may supply the resulting snapshot and visibility to the guard so one
# safety check performs only one platform scan.
capture_worktree_process_cwds() {
	if [[ -d /proc ]]; then
		_capture_worktree_proc_cwds /proc
		return $?
	fi

	if command -v lsof >/dev/null 2>&1; then
		# macOS lacks /proc, but `lsof +D <worktree>` recursively walks the
		# whole tree (including node_modules). Query only cwd descriptors once.
		_capture_worktree_lsof_cwds
		return $?
	fi
	return 1
}

# Return 0 when a captured cwd is inside the candidate worktree.
_worktree_cwd_snapshot_contains_path() {
	local wt_path="$1"
	local wt_path_real="$2"
	local cwd_snapshot="$3"
	local cwd_target=""

	if [[ -z "$wt_path" || -z "$wt_path_real" || -z "$cwd_snapshot" ]]; then
		return 1
	fi
	while IFS= read -r cwd_target; do
		case "$cwd_target" in
		"$wt_path" | "$wt_path"/* | "$wt_path_real" | "$wt_path_real"/*)
			return 0
			;;
		esac
	done <<<"$cwd_snapshot"
	return 1
}

# Return 0 when any live process has its current working directory inside the
# candidate worktree. `pgrep -f "$path"` only sees argv; commands such as
# linters often run with cwd inside the worktree while their argv contains no
# path, so deletion would make them fail with getcwd/uv_cwd ENOENT.
_worktree_has_process_cwd() {
	local wt_path="$1"
	local wt_path_real="$2"
	local cwd_snapshot=""
	local capture_status=0

	if [[ -z "$wt_path" || -z "$wt_path_real" ]]; then
		return 1
	fi
	if cwd_snapshot=$(capture_worktree_process_cwds); then
		capture_status=0
	else
		capture_status=$?
	fi
	if _worktree_cwd_snapshot_contains_path "$wt_path" "$wt_path_real" "$cwd_snapshot"; then
		return 0
	fi
	case "$capture_status" in
	0) return 1 ;;
	"$_WT_CWD_CAPTURE_DEGRADED_RC") return "$_WT_CWD_CAPTURE_DEGRADED_RC" ;;
	*) return "$_WT_CWD_MATCH_UNUSABLE_RC" ;;
	esac
}

# A porcelain block is complete when it describes either one bare repository or
# one linked worktree with exactly one HEAD and one branch/detached identity.
_worktree_git_block_is_complete() {
	local head_count="$1"
	local branch_count="$2"
	local detached_count="$3"
	local bare_count="$4"

	if [[ "$bare_count" -eq 1 ]]; then
		[[ "$head_count" -eq 0 && "$branch_count" -eq 0 && "$detached_count" -eq 0 ]]
		return $?
	fi
	[[ "$bare_count" -eq 0 && "$head_count" -eq 1 &&
		$((branch_count + detached_count)) -eq 1 ]]
	return $?
}

_worktree_git_head_payload_is_valid() {
	local head_oid="$1"

	[[ "${#head_oid}" -eq 40 || "${#head_oid}" -eq 64 ]] || return 1
	case "$head_oid" in
	*[!0-9a-fA-F]*) return 1 ;;
	esac
	return 0
}

_worktree_git_branch_payload_is_valid() {
	local branch_ref="$1"
	local branch_name=""
	local component=""
	local remaining=""

	case "$branch_ref" in
	refs/heads/*) ;;
	*) return 1 ;;
	esac
	branch_name="${branch_ref#refs/heads/}"
	[[ -n "$branch_name" ]] || return 1
	case "$branch_name" in
	*..* | *@\{* | /* | */ | *//* | *[[:space:]]* | *~* | *^* | *:* | *\?* | *\** | *\[* | *\\*) return 1 ;;
	esac
	remaining="$branch_name"
	while :; do
		component="${remaining%%/*}"
		[[ -n "$component" && "$component" != .* && "$component" != *. &&
			"$component" != *.lock ]] || return 1
		[[ "$remaining" == */* ]] || break
		remaining="${remaining#*/}"
	done
	return 0
}

_worktree_git_list_lock_state() {
	local wt_path="$1"
	local wt_path_real="$2"
	local candidate_root="$3"
	local field="" list_status="" listed_path=""
	local parser_valid=1 in_candidate=0 in_block=0 status_seen=0
	local candidate_seen=0 candidate_complete=0 candidate_locked=0
	local head_count=0 branch_count=0 detached_count=0 bare_count=0

	while IFS= read -r -d '' field; do
		case "$field" in
		"$_WT_GIT_STATUS_FIELD_PREFIX"*)
			[[ "$status_seen" -eq 0 && "$in_block" -eq 0 ]] || parser_valid=0
			list_status="${field#"$_WT_GIT_STATUS_FIELD_PREFIX"}"
			status_seen=1
			;;
		worktree\ *)
			[[ "$status_seen" -eq 0 && "$in_block" -eq 0 ]] || parser_valid=0
			listed_path="${field#worktree }"
			[[ -n "$listed_path" ]] || parser_valid=0
			in_block=1 in_candidate=0
			head_count=0 branch_count=0 detached_count=0 bare_count=0
			if [[ "$listed_path" == "$candidate_root" || "$listed_path" == "$wt_path" ||
				"$listed_path" == "$wt_path_real" ]]; then
				[[ "$candidate_seen" -eq 0 ]] || parser_valid=0
				in_candidate=1 candidate_seen=1
			fi
			;;
		HEAD\ *)
			head_count=$((head_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$head_count" -eq 1 ]] || parser_valid=0
			_worktree_git_head_payload_is_valid "${field#HEAD }" || parser_valid=0
			;;
		branch\ *)
			branch_count=$((branch_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$branch_count" -eq 1 ]] || parser_valid=0
			_worktree_git_branch_payload_is_valid "${field#branch }" || parser_valid=0
			;;
		detached)
			detached_count=$((detached_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$detached_count" -eq 1 ]] || parser_valid=0
			;;
		bare)
			bare_count=$((bare_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$bare_count" -eq 1 ]] || parser_valid=0
			;;
		locked | locked\ *)
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 ]] || parser_valid=0
			[[ "$in_candidate" -eq 0 ]] || candidate_locked=1
			;;
		"")
			if [[ "$status_seen" -eq 1 || "$in_block" -ne 1 ]]; then
				parser_valid=0
			elif _worktree_git_block_is_complete "$head_count" "$branch_count" "$detached_count" "$bare_count"; then
				[[ "$in_candidate" -eq 0 ]] || candidate_complete=1
			else
				parser_valid=0
			fi
			in_block=0 in_candidate=0
			;;
		*) [[ "$in_block" -eq 1 && "$status_seen" -eq 0 ]] || parser_valid=0 ;;
		esac
	done < <(
		git -C "$wt_path" worktree list --porcelain -z 2>/dev/null
		printf '%s%s\0' "$_WT_GIT_STATUS_FIELD_PREFIX" "$?"
	)

	if [[ "$parser_valid" -ne 1 || "$status_seen" -ne 1 || "$in_block" -ne 0 ||
		"$list_status" != "0" || "$candidate_seen" -ne 1 || "$candidate_complete" -ne 1 ]]; then
		printf '%s\n' "$_WT_GIT_STATE_UNREADABLE"
	elif [[ "$candidate_locked" -eq 1 ]]; then
		printf '%s\n' "$_WT_GIT_STATE_LOCKED"
	else
		printf '%s\n' "$_WT_GIT_STATE_CLEAR"
	fi
	return 0
}

# Classify the candidate's exact Git worktree metadata block. Git worktree
# locks are an explicit operator/session preservation boundary, so callers must
# not infer "unlocked" from a failed query or an unregistered-looking result.
# Args: $1=worktree path, $2=resolved worktree path
_worktree_git_lock_state() {
	local wt_path="$1"
	local wt_path_real="$2"
	local candidate_root=""

	if [[ ! -e "$wt_path" && ! -L "$wt_path" ]]; then
		printf '%s\n' "$_WT_GIT_STATE_NOT_WORKTREE"
		return 0
	fi
	if [[ ! -d "$wt_path" || ! -r "$wt_path" || ! -x "$wt_path" ]]; then
		printf '%s\n' "$_WT_GIT_STATE_UNREADABLE"
		return 0
	fi
	if ! candidate_root=$(git -C "$wt_path" rev-parse --show-toplevel 2>/dev/null); then
		if [[ -e "$wt_path/.git" || -L "$wt_path/.git" ]]; then
			printf '%s\n' "$_WT_GIT_STATE_UNREADABLE"
		else
			printf '%s\n' "$_WT_GIT_STATE_NOT_WORKTREE"
		fi
		return 0
	fi
	if [[ "$candidate_root" != "$wt_path" && "$candidate_root" != "$wt_path_real" ]]; then
		printf '%s\n' "$_WT_GIT_STATE_UNREADABLE"
		return 0
	fi
	_worktree_git_list_lock_state "$wt_path" "$wt_path_real" "$candidate_root"
	return 0
}

_worktree_git_common_dir() {
	local real_git="$1"
	local wt_path="$2"
	local common_dir=""

	common_dir=$("$real_git" -C "$wt_path" rev-parse --git-common-dir 2>/dev/null) || return 1
	if [[ "$common_dir" != /* ]]; then
		common_dir=$(cd "$wt_path/$common_dir" 2>/dev/null && pwd -P) || return 1
	else
		common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) || return 1
	fi
	printf '%s\n' "$common_dir"
	return 0
}

# Resolve an existing path physically, or reconstruct a missing path from its
# physical parent. The latter keeps Git's stored path comparable after a
# recoverable move on systems where /var and /private/var alias each other.
_worktree_physical_path() {
	local wt_path="$1"
	local clean_wt_path="$wt_path"
	local parent_path=""
	local parent_real=""
	local path_basename=""

	while [[ "$clean_wt_path" != "/" && "$clean_wt_path" == */ ]]; do
		clean_wt_path="${clean_wt_path%/}"
	done
	if [[ -d "$clean_wt_path" ]]; then
		(cd "$clean_wt_path" 2>/dev/null && pwd -P)
		return $?
	fi
	[[ "$clean_wt_path" == /* && "$clean_wt_path" != "/" ]] || return 1
	parent_path="${clean_wt_path%/*}"
	path_basename="${clean_wt_path##*/}"
	[[ -n "$parent_path" ]] || parent_path="/"
	[[ -n "$path_basename" ]] || return 1
	parent_real=$(cd "$parent_path" 2>/dev/null && pwd -P) || return 1
	if [[ "$parent_real" == "/" ]]; then
		printf '/%s\n' "$path_basename"
	else
		printf '%s/%s\n' "$parent_real" "$path_basename"
	fi
	return 0
}

_worktree_log_git_refusal() {
	local wt_path="$1"
	local caller="$2"
	local git_state="$3"
	local context="${4:-}"
	local refusal_reason="$_WT_GIT_REASON_UNREADABLE"

	if [[ "$git_state" == "$_WT_GIT_STATE_LOCKED" ]]; then
		refusal_reason="$_WT_GIT_REASON_LOCKED"
	elif [[ "$git_state" == "$_WT_GIT_STATE_CLEAR" ]]; then
		refusal_reason="$_WT_GIT_REASON_REMOVE_FAILED"
	fi
	WORKTREE_REMOVAL_GUARD_REASON="$refusal_reason"
	log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "$refusal_reason" "$_WTAR_MODE_SKIPPED" "$context"
	return 0
}

_worktree_log_identity_refusal() {
	local wt_path="$1"
	local caller="$2"
	local context="${3:-}"

	WORKTREE_REMOVAL_GUARD_REASON="$_WT_GIT_REASON_IDENTITY_CHANGED"
	log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" \
		"$_WT_GIT_REASON_IDENTITY_CHANGED" "$_WTAR_MODE_SKIPPED" "$context"
	return 0
}

_worktree_path_identity() {
	local target_path="$1"
	local platform=""

	[[ -e "$target_path" && ! -L "$target_path" ]] || return 1
	platform=$(uname -s 2>/dev/null) || return 1
	case "$platform" in
	Darwin) stat -f '%d:%i' "$target_path" 2>/dev/null || return 1 ;;
	Linux) stat -c '%d:%i' -- "$target_path" 2>/dev/null || return 1 ;;
	*) return 1 ;;
	esac
	return 0
}

# Copy exactly once into a unique destination. In particular, do not retry into
# a partially populated directory: cp changes semantics when the destination
# already exists, which could make a partial archive look complete.
_worktree_copy_directory_once() {
	local source_path="$1"
	local destination_path="$2"
	local platform=""

	[[ -d "$source_path" && ! -e "$destination_path" && ! -L "$destination_path" ]] || return 1
	platform=$(uname -s 2>/dev/null) || return 1
	case "$platform" in
	Darwin) cp -ac "$source_path" "$destination_path" 2>/dev/null || return 1 ;;
	Linux) cp -a --reflink=auto "$source_path" "$destination_path" 2>/dev/null || return 1 ;;
	*) cp -Rp "$source_path" "$destination_path" 2>/dev/null || return 1 ;;
	esac
	return 0
}

_worktree_capture_git_identity() {
	local wt_path="$1"
	local candidate_root=""
	local branch_status=0

	_WT_ID_REAL_GIT=""
	_WT_ID_SOURCE_REAL=""
	_WT_ID_SOURCE_INODE=""
	_WT_ID_ADMIN_REAL=""
	_WT_ID_ADMIN_INODE=""
	_WT_ID_COMMON_REAL=""
	_WT_ID_HEAD=""
	_WT_ID_BRANCH=""
	[[ -d "$wt_path" && ! -L "$wt_path" ]] || return 1
	_WT_ID_SOURCE_REAL=$(cd "$wt_path" 2>/dev/null && pwd -P) || return 1
	_WT_ID_SOURCE_INODE=$(_worktree_path_identity "$wt_path") || return 1
	_WT_ID_REAL_GIT=$(_worktree_cleanup_real_git) || return 1
	candidate_root=$("$_WT_ID_REAL_GIT" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || return 1
	candidate_root=$(cd "$candidate_root" 2>/dev/null && pwd -P) || return 1
	[[ "$candidate_root" == "$_WT_ID_SOURCE_REAL" ]] || return 1
	_WT_ID_ADMIN_REAL=$("$_WT_ID_REAL_GIT" -C "$wt_path" rev-parse --absolute-git-dir 2>/dev/null) || return 1
	_WT_ID_ADMIN_REAL=$(cd "$_WT_ID_ADMIN_REAL" 2>/dev/null && pwd -P) || return 1
	_WT_ID_ADMIN_INODE=$(_worktree_path_identity "$_WT_ID_ADMIN_REAL") || return 1
	_WT_ID_COMMON_REAL=$(_worktree_git_common_dir "$_WT_ID_REAL_GIT" "$wt_path") || return 1
	_WT_ID_HEAD=$("$_WT_ID_REAL_GIT" -C "$wt_path" rev-parse --verify HEAD 2>/dev/null) || return 1
	_worktree_git_head_payload_is_valid "$_WT_ID_HEAD" || return 1
	if _WT_ID_BRANCH=$("$_WT_ID_REAL_GIT" -C "$wt_path" symbolic-ref -q HEAD 2>/dev/null); then
		_worktree_git_branch_payload_is_valid "$_WT_ID_BRANCH" || return 1
	else
		branch_status=$?
		[[ "$branch_status" -eq 1 ]] || return 1
		_WT_ID_BRANCH="$_WT_RECOVERY_BRANCH_DETACHED"
	fi
	case "$_WT_ID_SOURCE_REAL$_WT_ID_ADMIN_REAL$_WT_ID_COMMON_REAL" in
	*$'\n'*) return 1 ;;
	esac
	return 0
}

_worktree_recovery_dir_for_archive() {
	local archive_path="$1"
	local archive_parent="${archive_path%/*}"

	[[ -n "$archive_path" && "$archive_parent" != "$archive_path" ]] || return 1
	printf '%s/%s\n' "$archive_parent" "$_WT_RECOVERY_DIR_NAME"
	return 0
}

_worktree_write_recovery_identity() {
	local recovery_dir="$1"

	printf '%s\n' "$_WT_RECOVERY_FORMAT" >"${recovery_dir}/format" || return 1
	printf '%s\n' "$_WT_ID_SOURCE_REAL" >"${recovery_dir}/source-real" || return 1
	printf '%s\n' "$_WT_ID_SOURCE_INODE" >"${recovery_dir}/source-inode" || return 1
	printf '%s\n' "$_WT_ID_ADMIN_REAL" >"${recovery_dir}/admin-real" || return 1
	printf '%s\n' "$_WT_ID_ADMIN_INODE" >"${recovery_dir}/admin-inode" || return 1
	printf '%s\n' "$_WT_ID_COMMON_REAL" >"${recovery_dir}/common-real" || return 1
	printf '%s\n' "$_WT_ID_HEAD" >"${recovery_dir}/head" || return 1
	printf '%s\n' "$_WT_ID_BRANCH" >"${recovery_dir}/branch" || return 1
	return 0
}

_worktree_recovery_archive_is_valid() {
	local archive_path="$1"
	local recovery_dir=""
	local recovery_admin=""
	local recovery_admin_real=""
	local format=""
	local expected_head=""
	local expected_branch=""
	local actual_admin=""
	local actual_head=""
	local real_git=""

	recovery_dir=$(_worktree_recovery_dir_for_archive "$archive_path") || return 1
	recovery_admin="${recovery_dir}/admin"
	[[ -d "$archive_path" && -f "$archive_path/.git" && ! -L "$archive_path/.git" ]] || return 1
	[[ -d "$recovery_admin" && -f "$recovery_admin/HEAD" && -f "$recovery_admin/index" ]] || return 1
	IFS= read -r format <"${recovery_dir}/format" || return 1
	IFS= read -r expected_head <"${recovery_dir}/head" || return 1
	IFS= read -r expected_branch <"${recovery_dir}/branch" || return 1
	[[ "$format" == "$_WT_RECOVERY_FORMAT" ]] || return 1
	_worktree_git_head_payload_is_valid "$expected_head" || return 1
	if [[ "$expected_branch" != "$_WT_RECOVERY_BRANCH_DETACHED" ]]; then
		_worktree_git_branch_payload_is_valid "$expected_branch" || return 1
	fi
	real_git=$(_worktree_cleanup_real_git) || return 1
	recovery_admin_real=$(cd "$recovery_admin" 2>/dev/null && pwd -P) || return 1
	actual_admin=$("$real_git" -C "$archive_path" rev-parse --absolute-git-dir 2>/dev/null) || return 1
	actual_admin=$(cd "$actual_admin" 2>/dev/null && pwd -P) || return 1
	[[ "$actual_admin" == "$recovery_admin_real" ]] || return 1
	actual_head=$("$real_git" -C "$archive_path" rev-parse --verify HEAD 2>/dev/null) || return 1
	[[ "$actual_head" == "$expected_head" ]] || return 1
	"$real_git" -C "$archive_path" status --porcelain=v1 -z --untracked-files=all >/dev/null 2>&1 || return 1
	return 0
}

_worktree_archive_source_matches() {
	local wt_path="$1"
	local archive_path="$2"
	local recovery_dir=""
	local expected_source_real=""
	local expected_source_inode=""
	local expected_admin_real=""
	local expected_admin_inode=""
	local expected_common_real=""
	local expected_head=""
	local expected_branch=""

	recovery_dir=$(_worktree_recovery_dir_for_archive "$archive_path") || return 1
	IFS= read -r expected_source_real <"${recovery_dir}/source-real" || return 1
	IFS= read -r expected_source_inode <"${recovery_dir}/source-inode" || return 1
	IFS= read -r expected_admin_real <"${recovery_dir}/admin-real" || return 1
	IFS= read -r expected_admin_inode <"${recovery_dir}/admin-inode" || return 1
	IFS= read -r expected_common_real <"${recovery_dir}/common-real" || return 1
	IFS= read -r expected_head <"${recovery_dir}/head" || return 1
	IFS= read -r expected_branch <"${recovery_dir}/branch" || return 1
	_worktree_capture_git_identity "$wt_path" || return 1
	[[ "$_WT_ID_SOURCE_REAL" == "$expected_source_real" ]] || return 1
	[[ "$_WT_ID_SOURCE_INODE" == "$expected_source_inode" ]] || return 1
	[[ "$_WT_ID_ADMIN_REAL" == "$expected_admin_real" ]] || return 1
	[[ "$_WT_ID_ADMIN_INODE" == "$expected_admin_inode" ]] || return 1
	[[ "$_WT_ID_COMMON_REAL" == "$expected_common_real" ]] || return 1
	[[ "$_WT_ID_HEAD" == "$expected_head" ]] || return 1
	[[ "$_WT_ID_BRANCH" == "$expected_branch" ]] || return 1
	return 0
}

archive_worktree_path_recoverably() {
	local wt_path="$1"
	local caller="$2"
	local context="${3:-}"
	local wt_path_real="$wt_path"
	local trash_root="${AIDEVOPS_WORKTREE_TRASH_ROOT:-${AIDEVOPS_ORPHAN_TRASH_ROOT:-}}"
	local trash_root_real=""
	local trash_bucket=""
	local archive_path=""
	local recovery_dir=""
	local recovery_admin=""
	local worktree_basename=""
	local git_state=""

	WORKTREE_RECOVERABLE_ARCHIVE_PATH=""
	_worktree_capture_git_identity "$wt_path" || return 1
	wt_path_real="$_WT_ID_SOURCE_REAL"
	git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") ||
		git_state="$_WT_GIT_STATE_UNREADABLE"
	if [[ "$git_state" != "$_WT_GIT_STATE_CLEAR" ]]; then
		_worktree_log_git_refusal "$wt_path" "$caller" "$git_state" "$context"
		return 1
	fi
	if [[ -z "$trash_root" ]]; then
		[[ -n "${HOME:-}" ]] || return 1
		trash_root="${HOME}/.Trash"
	fi
	[[ "$trash_root" == /* ]] || return 1
	mkdir -p "$trash_root" 2>/dev/null || return 1
	trash_root_real=$(cd "$trash_root" 2>/dev/null && pwd -P) || return 1
	case "$trash_root_real" in
	"$wt_path_real" | "$wt_path_real"/*) return 1 ;;
	esac
	worktree_basename="${wt_path%/}"
	worktree_basename="${worktree_basename##*/}"
	[[ -n "$worktree_basename" && "$worktree_basename" != "." &&
		"$worktree_basename" != "$_WT_RECOVERY_DIR_NAME" ]] || return 1
	trash_bucket="${trash_root_real}/aidevops-worktree-cleanup-$(date -u '+%Y%m%dT%H%M%SZ')-$$-${RANDOM}"
	archive_path="${trash_bucket}/${worktree_basename}"
	recovery_dir="${trash_bucket}/${_WT_RECOVERY_DIR_NAME}"
	recovery_admin="${recovery_dir}/admin"
	mkdir "$trash_bucket" 2>/dev/null || return 1
	_worktree_copy_directory_once "$wt_path_real" "$archive_path" || return 1
	mkdir "$recovery_dir" 2>/dev/null || return 1
	_worktree_copy_directory_once "$_WT_ID_ADMIN_REAL" "$recovery_admin" || return 1
	_worktree_write_recovery_identity "$recovery_dir" || return 1
	printf '%s\n' "$_WT_ID_HEAD" >"${recovery_admin}/HEAD" || return 1
	printf '%s\n' "$_WT_ID_COMMON_REAL" >"${recovery_admin}/commondir" || return 1
	printf '%s\n' "${archive_path}/.git" >"${recovery_admin}/gitdir" || return 1
	printf 'gitdir: %s\n' "$recovery_admin" >"${archive_path}/.git" || return 1
	_worktree_recovery_archive_is_valid "$archive_path" || return 1
	_worktree_archive_source_matches "$wt_path" "$archive_path" || return 1
	git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") ||
		git_state="$_WT_GIT_STATE_UNREADABLE"
	if [[ "$git_state" != "$_WT_GIT_STATE_CLEAR" ]]; then
		_worktree_log_git_refusal "$wt_path" "$caller" "$git_state" "$context"
		return 1
	fi
	WORKTREE_RECOVERABLE_ARCHIVE_PATH="$archive_path"
	return 0
}

_worktree_guard_path_is_usable() {
	local wt_path="$1"
	local caller="$2"

	if [[ -z "$wt_path" ]]; then
		WORKTREE_REMOVAL_GUARD_REASON="empty-path"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "empty-path" "$_WTAR_MODE_SKIPPED"
		return 1
	fi
	if [[ -L "$wt_path" ]]; then
		_worktree_log_identity_refusal "$wt_path" "$caller"
		return 1
	fi
	return 0
}

# =============================================================================
# worktree_removal_guard — shared destructive-path guard for production cleanup
#
# Args:
#   $1  wt_path  — absolute path candidate
#   $2  caller   — audit caller constant
#   $3  reason   — reason to log on skip
#   $4  cwd_snapshot — optional newline-separated live-process cwd snapshot
#   $5  cwd_visibility — complete, degraded, or unusable (default: complete)
#
# Refuses registered canonical repos, Git-locked or metadata-unreadable
# worktrees, the caller's current working directory, and worktrees that still
# have any live process cwd inside them. On refusal, WORKTREE_REMOVAL_GUARD_REASON
# contains the short audit reason for callers that opt into a user-facing
# diagnostic. The guard itself remains silent.
# Returns 0 for complete no-match, 2 for degraded no-match (recoverable path
# required), and 1 for every hard refusal or unusable snapshot.
# =============================================================================
worktree_removal_guard() {
	local wt_path="$1"
	local caller="$2"
	local reason="$3"
	local cwd_snapshot="${4:-}"
	local cwd_visibility="${5:-$_WT_CWD_VISIBILITY_COMPLETE}"
	local cwd_snapshot_provided=0
	local cwd_match_status=0
	local git_lock_state=""
	WORKTREE_REMOVAL_GUARD_REASON=""
	WORKTREE_REMOVAL_GUARD_VISIBILITY=""
	[[ "$#" -ge 4 ]] && cwd_snapshot_provided=1

	_worktree_guard_path_is_usable "$wt_path" "$caller" || return 1

	if command -v is_registered_canonical >/dev/null 2>&1; then
		if is_registered_canonical "$wt_path"; then
			WORKTREE_REMOVAL_GUARD_REASON="canonical-skip"
			log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "canonical-skip" "$_WTAR_MODE_SKIPPED"
			return 1
		fi
	fi

	local wt_path_real="$wt_path"
	if [[ -e "$wt_path" ]]; then
		wt_path_real=$(cd "$wt_path" 2>/dev/null && pwd -P) || wt_path_real="$wt_path"
	fi

	local current_dir=""
	current_dir=$(pwd -P 2>/dev/null || true)
	if [[ -n "$current_dir" ]]; then
		case "$current_dir" in
		"$wt_path" | "$wt_path"/* | "$wt_path_real" | "$wt_path_real"/*)
			WORKTREE_REMOVAL_GUARD_REASON="current-worktree"
			log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "current-worktree" "$_WTAR_MODE_SKIPPED"
			return 1
			;;
		esac
	fi

	git_lock_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") ||
		git_lock_state="$_WT_GIT_STATE_UNREADABLE"
	case "$git_lock_state" in
	"$_WT_GIT_STATE_LOCKED")
		WORKTREE_REMOVAL_GUARD_REASON="$_WT_GIT_REASON_LOCKED"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "$_WT_GIT_REASON_LOCKED" "$_WTAR_MODE_SKIPPED"
		return 1
		;;
	"$_WT_GIT_STATE_UNREADABLE")
		WORKTREE_REMOVAL_GUARD_REASON="$_WT_GIT_REASON_UNREADABLE"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "$_WT_GIT_REASON_UNREADABLE" "$_WTAR_MODE_SKIPPED"
		return 1
		;;
	esac

	if [[ "$cwd_snapshot_provided" -eq 1 ]]; then
		if _worktree_cwd_snapshot_contains_path "$wt_path" "$wt_path_real" "$cwd_snapshot"; then
			cwd_match_status=0
		else
			case "$cwd_visibility" in
			"$_WT_CWD_VISIBILITY_COMPLETE") cwd_match_status=1 ;;
			"$_WT_CWD_VISIBILITY_DEGRADED") cwd_match_status="$_WT_CWD_CAPTURE_DEGRADED_RC" ;;
			*) cwd_match_status="$_WT_CWD_MATCH_UNUSABLE_RC" ;;
			esac
		fi
	elif _worktree_has_process_cwd "$wt_path" "$wt_path_real"; then
		cwd_match_status=0
	else
		cwd_match_status=$?
	fi

	if [[ "$cwd_match_status" -eq 0 ]]; then
		WORKTREE_REMOVAL_GUARD_VISIBILITY="$cwd_visibility"
		WORKTREE_REMOVAL_GUARD_REASON="active-cwd"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "active-cwd" "$_WTAR_MODE_SKIPPED"
		return 1
	fi
	if [[ "$cwd_match_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]]; then
		WORKTREE_REMOVAL_GUARD_VISIBILITY="$_WT_CWD_VISIBILITY_DEGRADED"
		WORKTREE_REMOVAL_GUARD_REASON="$_WT_CWD_REASON_DEGRADED"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "$_WT_CWD_REASON_DEGRADED" "recoverable-required"
		return "$_WT_CWD_CAPTURE_DEGRADED_RC"
	fi
	if [[ "$cwd_match_status" -eq "$_WT_CWD_MATCH_UNUSABLE_RC" ]]; then
		WORKTREE_REMOVAL_GUARD_VISIBILITY="$_WT_CWD_VISIBILITY_UNUSABLE"
		WORKTREE_REMOVAL_GUARD_REASON="$_WT_CWD_REASON_UNUSABLE"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "$_WT_CWD_REASON_UNUSABLE" "$_WTAR_MODE_SKIPPED"
		return 1
	fi

	WORKTREE_REMOVAL_GUARD_VISIBILITY="$_WT_CWD_VISIBILITY_COMPLETE"
	: "$reason"
	return 0
}

_worktree_remove_with_native_git() {
	local wt_path="$1"
	local caller="$2"
	local context="$3"
	local force_remove="$4"
	local archive_path="${5:-}"
	local real_git=""
	local common_dir=""
	local wt_path_real="$wt_path"
	local git_state=""

	if [[ -L "$wt_path" ]]; then
		_worktree_log_identity_refusal "$wt_path" "$caller" "$context"
		return 1
	fi
	if [[ ! -e "$wt_path" ]]; then
		if [[ -n "$archive_path" ]]; then
			_worktree_log_identity_refusal "$wt_path" "$caller" "$context"
			return 1
		fi
		return 0
	fi
	if [[ -e "$wt_path" ]]; then
		wt_path_real=$(cd "$wt_path" 2>/dev/null && pwd -P) || wt_path_real="$wt_path"
	fi
	git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") ||
		git_state="$_WT_GIT_STATE_UNREADABLE"
	if [[ "$git_state" != "$_WT_GIT_STATE_CLEAR" ]]; then
		_worktree_log_git_refusal "$wt_path" "$caller" "$git_state" "$context"
		return 1
	fi
	if ! real_git=$(_worktree_cleanup_real_git); then
		_worktree_log_git_refusal "$wt_path" "$caller" "$_WT_GIT_STATE_UNREADABLE" "$context"
		return 1
	fi
	if ! common_dir=$(_worktree_git_common_dir "$real_git" "$wt_path"); then
		_worktree_log_git_refusal "$wt_path" "$caller" "$_WT_GIT_STATE_UNREADABLE" "$context"
		return 1
	fi
	if [[ -n "$archive_path" ]] && ! _worktree_archive_source_matches "$wt_path" "$archive_path"; then
		_worktree_log_identity_refusal "$wt_path" "$caller" "$context"
		return 1
	fi

	if [[ "$force_remove" == "$_WTAR_BOOL_TRUE" ]]; then
		# One force can remove dirty state, but Git requires force twice to
		# override a worktree lock acquired after our final metadata check.
		"$real_git" --git-dir="$common_dir" worktree remove --force "$wt_path_real" 2>/dev/null || {
			git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") ||
				git_state="$_WT_GIT_STATE_UNREADABLE"
			_worktree_log_git_refusal "$wt_path" "$caller" "$git_state" "$context"
			return 1
		}
	else
		"$real_git" --git-dir="$common_dir" worktree remove "$wt_path_real" 2>/dev/null || {
			git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") ||
				git_state="$_WT_GIT_STATE_UNREADABLE"
			_worktree_log_git_refusal "$wt_path" "$caller" "$git_state" "$context"
			return 1
		}
	fi
	[[ ! -e "$wt_path" && ! -e "$wt_path_real" ]] || return 1
	return 0
}

# Remove a registered worktree only after a durable copy exists outside it.
# Native Git remains the final authority, so a lock acquired during the archive
# copy blocks source removal without any temporary lock-release protocol.
# Args: $1=worktree, $2=archive, $3=caller, $4=reason, $5=context,
#       $6=allow degraded CWD evidence, $7=allow one force
remove_archived_worktree_path() {
	local wt_path="$1"
	local archive_path="$2"
	local caller="$3"
	local reason="$4"
	local context="${5:-}"
	local allow_degraded="${6:-false}"
	local force_remove="${7:-false}"
	local archive_path_real=""
	local wt_path_real="$wt_path"
	local guard_status=0

	_worktree_recovery_archive_is_valid "$archive_path" || return 1
	archive_path_real=$(cd "$archive_path" 2>/dev/null && pwd -P) || return 1
	if [[ -e "$wt_path" ]]; then
		wt_path_real=$(cd "$wt_path" 2>/dev/null && pwd -P) || return 1
	fi
	case "$archive_path_real" in
	"$wt_path_real" | "$wt_path_real"/*) return 1 ;;
	esac
	if ! _worktree_archive_source_matches "$wt_path" "$archive_path"; then
		_worktree_log_identity_refusal "$wt_path" "$caller" "$context"
		return 1
	fi
	if worktree_removal_guard "$wt_path" "$caller" "$reason"; then
		guard_status=0
	else
		guard_status=$?
	fi
	if [[ "$guard_status" -ne 0 ]]; then
		[[ "$allow_degraded" == "$_WTAR_BOOL_TRUE" && "$guard_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || return 1
	fi
	_worktree_remove_with_native_git "$wt_path" "$caller" "$context" "$force_remove" "$archive_path" || return 1
	_worktree_recovery_archive_is_valid "$archive_path" || return 1
	return 0
}

# =============================================================================
# remove_worktree_path_permanently — guarded direct delete for verified cleanup
#
# Args:
#   $1  wt_path  — absolute path candidate
#   $2  caller   — audit caller constant
#   $3  reason   — audit reason on removal
#   $4  context  — optional safe key=value guard context
#
# Returns 0 when path is gone, 1 on guard/delete failure.
# =============================================================================
remove_worktree_path_permanently() {
	local wt_path="$1"
	local caller="$2"
	local reason="$3"
	local context="${4:-}"

	worktree_removal_guard "$wt_path" "$caller" "$reason" || return 1
	if _worktree_remove_with_native_git "$wt_path" "$caller" "$context" "false"; then
		log_worktree_removal_event "$_WTAR_REMOVED" "$caller" "$wt_path" "$reason" "permanent" "$context"
		return 0
	fi

	return 1
}

# Resolve native Git without selecting the canonical mutation-guard shim. This
# helper is the audited exception for an already-guarded linked worktree's
# lock-aware removal and missing-metadata prune operations.
_worktree_cleanup_real_git() {
	local candidate="${AIDEVOPS_REAL_GIT_BIN:-}"

	if [[ -n "$candidate" && -x "$candidate" ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi

	for candidate in /usr/bin/git /usr/local/bin/git /opt/homebrew/bin/git; do
		if [[ -x "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done

	return 1
}

# Return 0 when Git still lists the exact worktree path in its shared metadata.
_worktree_metadata_contains_path() {
	local real_git="$1"
	local repo_context="$2"
	local wt_path="$3"
	local clean_wt_path="$wt_path"
	local physical_wt_path="$wt_path"
	local field="" list_status="" listed_path=""
	local parser_valid=1 in_block=0 status_seen=0 target_seen=0
	local head_count=0 branch_count=0 detached_count=0 bare_count=0

	while [[ "$clean_wt_path" != "/" && "$clean_wt_path" == */ ]]; do
		clean_wt_path="${clean_wt_path%/}"
	done
	physical_wt_path=$(_worktree_physical_path "$clean_wt_path") || physical_wt_path="$clean_wt_path"
	while IFS= read -r -d '' field; do
		case "$field" in
		"$_WT_GIT_STATUS_FIELD_PREFIX"*)
			[[ "$status_seen" -eq 0 && "$in_block" -eq 0 ]] || parser_valid=0
			list_status="${field#"$_WT_GIT_STATUS_FIELD_PREFIX"}"
			status_seen=1
			;;
		worktree\ *)
			[[ "$status_seen" -eq 0 && "$in_block" -eq 0 ]] || parser_valid=0
			listed_path="${field#worktree }"
			[[ -n "$listed_path" ]] || parser_valid=0
			in_block=1
			head_count=0 branch_count=0 detached_count=0 bare_count=0
			if [[ "$listed_path" == "$clean_wt_path" || "$listed_path" == "$physical_wt_path" ]]; then
				[[ "$target_seen" -eq 0 ]] || parser_valid=0
				target_seen=1
			fi
			;;
		HEAD\ *)
			head_count=$((head_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$head_count" -eq 1 ]] || parser_valid=0
			_worktree_git_head_payload_is_valid "${field#HEAD }" || parser_valid=0
			;;
		branch\ *)
			branch_count=$((branch_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$branch_count" -eq 1 ]] || parser_valid=0
			_worktree_git_branch_payload_is_valid "${field#branch }" || parser_valid=0
			;;
		detached)
			detached_count=$((detached_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$detached_count" -eq 1 ]] || parser_valid=0
			;;
		bare)
			bare_count=$((bare_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$bare_count" -eq 1 ]] || parser_valid=0
			;;
		"")
			if [[ "$status_seen" -eq 1 || "$in_block" -ne 1 ]] ||
				! _worktree_git_block_is_complete "$head_count" "$branch_count" "$detached_count" "$bare_count"; then
				parser_valid=0
			fi
			in_block=0
			;;
		*) [[ "$in_block" -eq 1 && "$status_seen" -eq 0 ]] || parser_valid=0 ;;
		esac
	done < <(
		"$real_git" -C "$repo_context" worktree list --porcelain -z 2>/dev/null
		printf '%s%s\0' "$_WT_GIT_STATUS_FIELD_PREFIX" "$?"
	)
	if [[ "$parser_valid" -ne 1 || "$status_seen" -ne 1 || "$in_block" -ne 0 || "$list_status" != "0" ]]; then
		return 2
	fi
	[[ "$target_seen" -eq 0 ]] || return 0

	return 1
}

# Prune a missing linked worktree through the narrowly scoped native-Git
# primitive, then verify its exact metadata entry disappeared. The target must
# already be absent so this cannot remove a live worktree directory.
# Args: $1=repository context, $2=missing worktree path
# Returns 0 only when the target metadata is absent after pruning.
prune_missing_worktree_metadata() {
	local repo_context="$1"
	local wt_path="$2"
	local real_git=""
	local metadata_status=0

	[[ -n "$repo_context" && -d "$repo_context" && -n "$wt_path" ]] || return 1
	[[ ! -e "$wt_path" ]] || return 1
	real_git=$(_worktree_cleanup_real_git) || return 1
	[[ -n "$real_git" ]] || return 1

	if _worktree_metadata_contains_path "$real_git" "$repo_context" "$wt_path"; then
		metadata_status=0
	else
		metadata_status=$?
	fi
	if [[ "$metadata_status" -eq 1 ]]; then
		return 0
	elif [[ "$metadata_status" -ne 0 ]]; then
		return 1
	fi

	"$real_git" -C "$repo_context" worktree prune >/dev/null || return 1
	if _worktree_metadata_contains_path "$real_git" "$repo_context" "$wt_path"; then
		metadata_status=0
	else
		metadata_status=$?
	fi
	[[ "$metadata_status" -eq 1 ]] || return 1

	return 0
}
