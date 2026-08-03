#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Claim Task ID — Counter/Allocation Sub-Library
# =============================================================================
# CAS (compare-and-swap) counter management and ID allocation functions
# extracted from claim-task-id.sh.
#
# Covers:
#   1. Counter reads (local and remote)
#   2. Counter bootstrap (seed from TODO.md on first use)
#   3. CAS loop (fetch → pin → build → push, with wall-clock timeout)
#   4. Online allocation (with collision-avoidance against existing TODO entries)
#   5. Offline allocation (with +OFFLINE_OFFSET safety gap)
#
# Usage: source "${SCRIPT_DIR}/claim-task-id-counter.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error, log_success)
#   - Global variables from claim-task-id.sh:
#       REMOTE_NAME, COUNTER_BRANCH, COUNTER_FILE
#       CAS_MAX_RETRIES, CAS_WALL_TIMEOUT_S, CAS_GIT_CMD_TIMEOUT_S
#       CAS_HTTPS_TIMEOUT_S, CAS_SSH_FALLBACK_ENABLED  (GH#21904)
#       CAS_EXHAUSTION_FATAL, OFFLINE_OFFSET
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CLAIM_TASK_ID_COUNTER_LIB_LOADED:-}" ]] && return 0
_CLAIM_TASK_ID_COUNTER_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh:35-41 pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Formatting Helpers
# =============================================================================

# Preserve the public claim-task-id.sh setup-error exit contract through every
# allocation layer. A protected-branch rejection is policy, not contention, so
# callers must not reconcile and attempt the same forbidden push again.
CAS_PROTECTED_BRANCH_RC="${CAS_PROTECTED_BRANCH_RC:-4}"

# Format a task ID range for log messages and commit subjects.
# Args: $1 first numeric ID, $2 last numeric ID.
# Outputs: e.g. "t042..t045"
_format_task_range() {
	local first_num="$1"
	local last_num="$2"
	printf 't%03d..t%03d' "$first_num" "$last_num"
}

# Machine-local coordinator integration. Legacy CAS remains authoritative unless
# AIDEVOPS_TASK_COORDINATOR_MODE is explicitly set to shadow or namespaced.
_task_coordinator_cli() {
	printf '%s/task-coordinator.mjs' "$SCRIPT_DIR"
	return 0
}

_task_coordinator_shadow_legacy() {
	local first_id="$1"
	local count="$2"
	[[ "${AIDEVOPS_TASK_COORDINATOR_MODE:-legacy}" == "shadow" ]] || return 0
	[[ "${AIDEVOPS_TASK_COORDINATOR_SHADOW_ENABLED:-0}" == "1" ]] || return 0
	local cli=""
	cli=$(_task_coordinator_cli)
	local operation_id="legacy-${AIDEVOPS_SESSION_ID:-${BASHPID:-$$}}-${first_id}-${count}"
	local legacy_id=""
	printf -v legacy_id 't%03d' "$first_id"
	if ! node "$cli" allocate --operation-id "$operation_id" --count "$count" \
		--legacy-id "$legacy_id" --payload '{"source":"legacy-cas-shadow"}' >/dev/null; then
		log_warn "Task coordinator shadow write failed; legacy CAS allocation remains valid"
		return 0
	fi
	log_info "Task coordinator shadow recorded ${legacy_id} without changing emitted identity"
	return 0
}

_task_coordinator_namespaced_allocate() {
	local count="$1"
	[[ "${AIDEVOPS_TASK_COORDINATOR_MODE:-legacy}" == "namespaced" ]] || return 1
	if [[ "${AIDEVOPS_TASK_COORDINATOR_NAMESPACED_EMISSION_ENABLED:-0}" != "1" ]]; then
		log_error "Namespaced coordinator mode requires AIDEVOPS_TASK_COORDINATOR_NAMESPACED_EMISSION_ENABLED=1"
		return 2
	fi
	local cli=""
	cli=$(_task_coordinator_cli)
	node "$cli" allocate --operation-id "${AIDEVOPS_TASK_OPERATION_ID:-$(uuidgen 2>/dev/null || printf 'claim-%s-%s' "${BASHPID:-$$}" "$RANDOM")}" \
		--count "$count" --payload '{"source":"claim-task-id"}'
	return $?
}

# ---------------------------------------------------------------------------
# Append a structured audit log line for a successful CAS claim.
# Format: ISO8601 \t pid \t session_id \t tNNN \t attempt \t elapsed_s
# (tab-separated so later tooling can parse without quoting concerns.)
# Log file: ~/.aidevops/logs/task-claim.log (created on first append).
#
# Phase 3 (t2569 / GH#20001): forensics for CAS-race or reuse incidents.
# ---------------------------------------------------------------------------
_append_claim_audit_log() {
	local first_id="${1:-}"
	local attempt="${2:-1}"
	local elapsed="${3:-0}"

	[[ -z "$first_id" ]] && return 0

	local log_dir="${HOME}/.aidevops/logs"
	local log_file="${log_dir}/task-claim.log"

	mkdir -p "$log_dir" 2>/dev/null || return 0

	local ts pid sid tid
	ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
	pid="${BASHPID:-$$}"
	sid="${AIDEVOPS_SESSION_ID:-${Claude_SESSION_ID:-${OPENCODE_SESSION_ID:-unknown}}}"
	tid=$(printf 't%03d' "$first_id")

	# Tab-separated; single append is atomic on POSIX filesystems for short writes.
	printf '%s\t%s\t%s\t%s\t%s\t%ss\n' \
		"$ts" "$pid" "$sid" "$tid" "$attempt" "$elapsed" >> "$log_file" 2>/dev/null || true
	return 0
}

# =============================================================================
# HTTPS timeout + SSH fallback for CAS git operations (GH#21904)
# =============================================================================
# The CAS path (`git fetch`/`git push` against the counter branch) hangs
# indefinitely when git's HTTPS credential helper stalls — observed with
# osxkeychain on macOS, libsecret/manager-core on Linux. The existing
# `http.lowSpeedTime` only fires once bytes start flowing; credential
# negotiation hangs happen BEFORE the transport is established and bypass it.
#
# Mitigation: wrap each call with `timeout_sec` (from shared-constants.sh).
# On timeout (exit 124) OR other git failure against an HTTPS-GitHub remote,
# derive the SSH-equivalent URL and retry once via
# `-c url.<ssh>.insteadOf=<https>` so the original `$REMOTE_NAME` ref-name
# still resolves. Retrying non-timeout failures lets `GIT_ASKPASS=/bin/false`
# and stale/broken credential-helper paths recover without waiting for a hang.
#
# `gh` CLI authenticates via the ssh-protocol preference by default, so SSH
# pushes succeed when the gh-managed token (used by HTTPS) is unreachable.
#
# Memory: mem_20260430054453_5f0d112e (HTTPS push hung; SSH workaround
# verified to complete in <10s on the same network).

# Convert a GitHub HTTPS clone URL to its SSH equivalent.
# Args: $1 — input URL.
# Stdout: SSH-form URL on conversion, empty on no-conversion.
# Returns: 0 on conversion (stdout populated), 1 on no-conversion.
#
# Examples:
#   https://github.com/owner/repo.git → git@github.com:owner/repo.git
#   https://github.com/owner/repo     → git@github.com:owner/repo
#   git@github.com:owner/repo.git     → "" (already SSH; rc=1)
#   https://gitlab.com/owner/repo.git → "" (only GitHub for now; rc=1)
_derive_ssh_url_from_https() {
	local url="${1:-}"
	[[ -z "$url" ]] && return 1
	# Match `https://github.com/<owner>/<repo>` with optional .git suffix.
	# Bash 3.2 compatible regex (no \K, no lookaheads).
	if [[ "$url" =~ ^https://github\.com/([^/[:space:]]+/[^/[:space:]]+)(\.git)?$ ]]; then
		local path="${BASH_REMATCH[1]}"
		local suffix="${BASH_REMATCH[2]}"
		# Trim any trailing slashes from path before the (optional) .git suffix
		path="${path%/}"
		printf 'git@github.com:%s%s' "$path" "$suffix"
		return 0
	fi
	return 1
}

# Run a git command with a wall-clock timeout and HTTPS→SSH fallback.
# Args: $1 — timeout in seconds, $2..$N — git subcommand and its arguments
#       (do NOT include the leading `git`; this helper adds it).
# Returns: the git command's exit code on success or non-timeout failure;
#          124 if both attempts time out (or fallback is disabled / not
#          applicable after a timeout). On HTTPS failure + successful SSH retry,
#          returns 0.
#
# Behaviour matrix:
#   HTTPS succeeds within timeout              → return 0
#   HTTPS fails non-timeout + fallback succeeds → return 0
#   HTTPS fails non-timeout + fallback fails    → return fallback rc
#   HTTPS times out, remote NOT https-github    → return 124 (no fallback)
#   HTTPS times out, fallback disabled          → return 124 (no fallback)
#   HTTPS times out, fallback runs and succeeds → return 0
#   HTTPS times out, fallback also times out    → return 124
_run_git_with_ssh_fallback() {
	local timeout_s="$1"
	shift
	# First attempt — pass through unchanged. Quote "$@" so subcommand args
	# survive whitespace, glob chars, etc.
	local rc=0
	timeout_sec "$timeout_s" git "$@" || rc=$?
	if [[ $rc -eq 0 ]]; then
		return $rc
	fi

	# Failure path. Check whether SSH fallback applies.
	if [[ "${CAS_SSH_FALLBACK_ENABLED:-1}" != "1" ]]; then
		if [[ $rc -eq 124 ]]; then
			log_warn "git timed out after ${timeout_s}s (CAS_SSH_FALLBACK_ENABLED=0 — no retry)"
		else
			log_warn "git failed with rc=${rc} (CAS_SSH_FALLBACK_ENABLED=0 — no retry)"
		fi
		return $rc
	fi

	local current_url
	current_url=$(git remote get-url "${REMOTE_NAME:-origin}" 2>/dev/null) || {
		if [[ $rc -eq 124 ]]; then
			log_warn "git timed out after ${timeout_s}s (could not resolve ${REMOTE_NAME:-origin} URL — no fallback)"
		else
			log_warn "git failed with rc=${rc} (could not resolve ${REMOTE_NAME:-origin} URL — no fallback)"
		fi
		return $rc
	}

	local ssh_url=""
	ssh_url=$(_derive_ssh_url_from_https "$current_url") || true
	if [[ -z "$ssh_url" ]]; then
		# Already SSH, or non-GitHub HTTPS — no fallback applies.
		if [[ $rc -eq 124 ]]; then
			log_warn "git timed out after ${timeout_s}s on ${current_url} (no HTTPS-GitHub → SSH fallback applies)"
		else
			log_warn "git failed with rc=${rc} on ${current_url} (no HTTPS-GitHub → SSH fallback applies)"
		fi
		return $rc
	fi

	if [[ $rc -eq 124 ]]; then
		log_warn "git timed out after ${timeout_s}s on HTTPS — retrying via SSH (${ssh_url})"
	else
		log_warn "git failed with rc=${rc} on HTTPS — retrying via SSH (${ssh_url})"
	fi
	rc=0
	timeout_sec "$timeout_s" git -c "url.${ssh_url}.insteadOf=${current_url}" "$@" || rc=$?
	if [[ $rc -eq 0 ]]; then
		log_info "SSH fallback succeeded — HTTPS push hang transparent to caller (GH#21904)"
	elif [[ $rc -eq 124 ]]; then
		log_warn "SSH fallback also timed out after ${timeout_s}s — both transports unavailable"
	fi
	return $rc
}

# Prefer the conventional dedicated branch when neither CLI nor project config
# selected a counter branch. The candidate is accepted only when its counter is
# at least the default-branch counter and the TODO-derived seed, preventing an
# implicit migration from reusing IDs or introducing a migration gap.
resolve_implicit_counter_branch() {
	local repo_path="$1"
	local candidate="${AIDEVOPS_DEDICATED_COUNTER_BRANCH:-task-id-counter}"
	local candidate_counter=""
	local default_counter="0"
	local todo_seed="0"

	[[ "${_COUNTER_BRANCH_SET:-false}" == "false" ]] || return 0
	[[ "${OFFLINE_MODE:-false}" == "false" ]] || return 0
	[[ "$COUNTER_BRANCH" == "${DEFAULT_BRANCH:-main}" ]] || return 0
	[[ -n "$candidate" && "$candidate" != "$COUNTER_BRANCH" ]] || return 0
	cd "$repo_path" || return 1

	if ! _run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		fetch -q "$REMOTE_NAME" "$candidate" >/dev/null; then
		return 0
	fi
	candidate_counter=$(git show "${REMOTE_NAME}/${candidate}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
	[[ "$candidate_counter" =~ ^[0-9]+$ ]] || return 0

	_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		fetch -q "$REMOTE_NAME" "${DEFAULT_BRANCH:-main}" >/dev/null || true
	default_counter=$(git show "${REMOTE_NAME}/${DEFAULT_BRANCH:-main}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
	[[ "$default_counter" =~ ^[0-9]+$ ]] || default_counter="0"
	todo_seed=$(_compute_counter_seed "$repo_path")

	if ((10#$candidate_counter < 10#$default_counter || 10#$candidate_counter < 10#$todo_seed)); then
		log_warn "Dedicated counter branch ${REMOTE_NAME}/${candidate} is behind canonical task state; refusing implicit migration"
		return 0
	fi

	COUNTER_BRANCH="$candidate"
	log_info "counter branch auto-selected from validated dedicated branch: ${COUNTER_BRANCH}"
	return 0
}

# Resolve the GitHub owner/repository slug from the configured remote without
# applying git url.*.insteadOf rewrites. The raw value lets fixtures route a
# GitHub-shaped URL to a local bare repository while production still queries
# the policy for the configured remote.
_cas_extract_github_slug() {
	local repo_path="$1"
	local remote_url=""
	local slug=""

	remote_url=$(git -C "$repo_path" config --get "remote.${REMOTE_NAME}.url" 2>/dev/null || true)
	[[ -n "$remote_url" ]] || return 1
	remote_url="${remote_url%.git}"

	case "$remote_url" in
	https://github.com/*)
		slug="${remote_url#https://github.com/}"
		;;
	git@github.com:*)
		slug="${remote_url#git@github.com:}"
		;;
	ssh://git@github.com/*)
		slug="${remote_url#ssh://git@github.com/}"
		;;
	*)
		return 1
		;;
	esac

	[[ "$slug" =~ ^[^/]+/[^/]+$ ]] || return 1
	printf '%s\n' "$slug"
	return 0
}

# Return success only when GitHub reports that the configured counter branch
# requires pull-request updates. Classic protection and modern rulesets expose
# that requirement through separate REST endpoints, so inspect both. API
# failures remain fail-open here; the push-time rejection classifier below is
# retained as the provider-independent final safety net.
_cas_github_branch_requires_pull_request() {
	local slug="$1"
	local protection_json=""
	local rules_json=""
	local protection_rc=0
	local rules_rc=0

	protection_json=$(gh api "repos/${slug}/branches/${COUNTER_BRANCH}/protection" 2>/dev/null) || protection_rc=$?
	if [[ $protection_rc -eq 0 ]] \
		&& jq -e '.required_pull_request_reviews != null' >/dev/null 2>&1 <<<"$protection_json"; then
		return 0
	fi

	rules_json=$(gh api "repos/${slug}/rules/branches/${COUNTER_BRANCH}" 2>/dev/null) || rules_rc=$?
	if [[ $rules_rc -eq 0 ]] \
		&& jq -e 'any(.[]; .type == "pull_request")' >/dev/null 2>&1 <<<"$rules_json"; then
		return 0
	fi

	return 1
}

_cas_log_counter_branch_remediation() {
	log_error "Recovery: initialize a dedicated unprotected counter branch from the current ${COUNTER_FILE} value,"
	log_error "then set .aidevops.json counter_branch to that branch (for example, \"task-id-counter\")."
	log_error "Keep ${DEFAULT_BRANCH:-main} pull-request protection unchanged; do not emulate CAS through a pull request."
	return 0
}

# Reject a known PR-only counter branch before any fetch, object creation, or
# push can advance the allocation state.
preflight_counter_branch_policy() {
	local repo_path="$1"
	local slug=""

	[[ "${OFFLINE_MODE:-false}" == "false" ]] || return 0
	[[ "${DRY_RUN:-false}" == "false" ]] || return 0
	command -v gh >/dev/null 2>&1 || return 0
	command -v jq >/dev/null 2>&1 || return 0
	slug=$(_cas_extract_github_slug "$repo_path") || return 0

	if _cas_github_branch_requires_pull_request "$slug"; then
		log_error "PROTECTED_COUNTER_BRANCH: ${REMOTE_NAME}/${COUNTER_BRANCH} requires pull-request updates"
		log_error "Task ID allocation stopped before reading or advancing ${COUNTER_FILE}."
		_cas_log_counter_branch_remediation
		_task_counter_status "setup_error" "protected_counter_branch"
		return 1
	fi

	return 0
}

# Detect GitHub protected-branch rejections in git push stderr.
# These are policy failures, not CAS contention, so retrying only burns the
# wall-clock budget and hides the actionable remediation.
_cas_push_rejection_is_protected_branch() {
	local stderr_text="${1:-}"

	[[ -z "$stderr_text" ]] && return 1
	if [[ "$stderr_text" == *"Protected branch update failed"* ]]; then
		return 0
	fi
	if [[ "$stderr_text" == *"GH006"* && "$stderr_text" == *"Changes must be made through a pull request"* ]]; then
		return 0
	fi
	if [[ "$stderr_text" == *"Changes must be made through a pull request"* && "$stderr_text" == *"refs/heads/${COUNTER_BRANCH}"* ]]; then
		return 0
	fi
	return 1
}

# Emit protected-branch guidance without exposing full remote URLs or stderr.
_cas_log_protected_branch_rejection() {
	log_error "PROTECTED_COUNTER_BRANCH: ${REMOTE_NAME}/${COUNTER_BRANCH} rejects direct counter pushes"
	log_error "Task ID allocation cannot advance ${COUNTER_FILE} by direct CAS push on a protected branch."
	_cas_log_counter_branch_remediation
	log_error "The CAS helper used git plumbing only; no working-tree changes or local commits were created."
	return 0
}

# Emit a stable machine-readable allocation status without contaminating stdout.
# Stdout is reserved for claim-task-id.sh key=value results; status belongs on
# stderr via log_info so wrappers can parse it without breaking callers.
_task_counter_status() {
	local status="$1"
	local detail="${2:-}"
	if [[ -n "$detail" ]]; then
		log_info "AIDEVOPS_TASK_COUNTER_STATUS=${status} detail=${detail}"
	else
		log_info "AIDEVOPS_TASK_COUNTER_STATUS=${status}"
	fi
	return 0
}

_cas_fetch_counter_branch_for_reconcile() {
	local repo_path="$1"

	cd "$repo_path" || return 1
	_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		fetch -q "$REMOTE_NAME" "$COUNTER_BRANCH" >/dev/null || {
		log_error "UNRECOVERABLE_COUNTER_DESYNC: cannot fetch ${REMOTE_NAME}/${COUNTER_BRANCH} for reconciliation"
		_task_counter_status "unrecoverable_desync" "fetch_failed"
		return 1
	}
	return 0
}

_cas_resolve_counter_ref_for_reconcile() {
	local counter_ref="$1"

	git rev-parse "$counter_ref" 2>/dev/null || {
		log_error "UNRECOVERABLE_COUNTER_DESYNC: cannot resolve ${counter_ref} after fetch"
		_task_counter_status "unrecoverable_desync" "resolve_failed"
		return 1
	}
	return 0
}

_cas_read_counter_file_from_ref() {
	local ref_sha="$1"
	local repo_path="$2"
	local counter_value=""

	counter_value=$(git show "${ref_sha}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
	if [[ -z "$counter_value" ]] || ! [[ "$counter_value" =~ ^[0-9]+$ ]]; then
		counter_value=$(_compute_counter_seed "$repo_path")
	fi
	printf '%s\n' "$counter_value"
	return 0
}

_cas_read_default_counter_for_reconcile() {
	local default_branch="$1"
	local default_counter="0"
	local default_ref=""

	if [[ -n "$default_branch" && "$default_branch" != "$COUNTER_BRANCH" ]]; then
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			fetch -q "$REMOTE_NAME" "$default_branch" >/dev/null || true
		default_ref="${REMOTE_NAME}/${default_branch}"
		default_counter=$(git show "${default_ref}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
		if [[ -z "$default_counter" ]] || ! [[ "$default_counter" =~ ^[0-9]+$ ]]; then
			default_counter="0"
		fi
	fi
	printf '%s\n' "$default_counter"
	return 0
}

_cas_reconciled_counter_value() {
	local repo_path="$1"
	local branch_counter="$2"
	local default_counter="$3"
	local todo_seed=""
	local reconciled_counter="$branch_counter"

	todo_seed=$(_compute_counter_seed "$repo_path")
	((10#$default_counter > 10#$reconciled_counter)) && reconciled_counter="$default_counter"
	((10#$todo_seed > 10#$reconciled_counter)) && reconciled_counter="$todo_seed"
	printf '%s\n' "$reconciled_counter"
	return 0
}

_cas_build_reconciled_counter_tree() {
	local pinned_sha="$1"
	local reconciled_counter="$2"
	local blob_sha existing_tree tree_sha

	blob_sha=$(printf '%s\n' "$reconciled_counter" | git hash-object -w --stdin 2>/dev/null) || {
		log_error "UNRECOVERABLE_COUNTER_DESYNC: failed to create reconciled counter blob"
		_task_counter_status "unrecoverable_desync" "blob_failed"
		return 1
	}
	existing_tree=$(git ls-tree "$pinned_sha") || {
		log_error "UNRECOVERABLE_COUNTER_DESYNC: failed to inspect reconciled counter tree"
		_task_counter_status "unrecoverable_desync" "tree_read_failed"
		return 1
	}
	if printf '%s\n' "$existing_tree" | grep -q "${COUNTER_FILE}$"; then
		tree_sha=$(printf '%s\n' "$existing_tree" | sed "s|[0-9a-f]\{40,64\}	${COUNTER_FILE}$|${blob_sha}	${COUNTER_FILE}|" | git mktree) || {
			log_error "UNRECOVERABLE_COUNTER_DESYNC: failed to replace reconciled counter tree entry"
			_task_counter_status "unrecoverable_desync" "tree_replace_failed"
			return 1
		}
	else
		tree_sha=$(
			{
				[[ -n "$existing_tree" ]] && printf '%s\n' "$existing_tree"
				printf '100644 blob %s\t%s\n' "$blob_sha" "$COUNTER_FILE"
			} | git mktree
		) || {
			log_error "UNRECOVERABLE_COUNTER_DESYNC: failed to add reconciled counter tree entry"
			_task_counter_status "unrecoverable_desync" "tree_add_failed"
			return 1
		}
	fi
	printf '%s\n' "$tree_sha"
	return 0
}

_cas_create_reconciliation_commit() {
	local pinned_sha="$1"
	local tree_sha="$2"
	local branch_counter="$3"
	local reconciled_counter="$4"

	git commit-tree "$tree_sha" -p "$pinned_sha" -m "chore: reconcile task counter (${branch_counter}->${reconciled_counter})" 2>/dev/null || {
		log_error "UNRECOVERABLE_COUNTER_DESYNC: failed to create reconciliation commit"
		_task_counter_status "unrecoverable_desync" "commit_failed"
		return 1
	}
	return 0
}

_cas_push_reconciliation_commit() {
	local commit_sha="$1"
	local push_rc=0
	local push_stderr=""
	local push_err_file=""

	push_err_file=$(mktemp "${TMPDIR:-/tmp}/claim-task-id-reconcile-push.XXXXXX" 2>/dev/null) || push_err_file=""
	if [[ -n "$push_err_file" ]]; then
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			push -q "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" >/dev/null 2>"$push_err_file" || push_rc=$?
	else
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			push -q "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" >/dev/null || push_rc=$?
	fi
	if [[ -n "$push_err_file" ]]; then
		push_stderr=$(<"$push_err_file")
		rm -f "$push_err_file" 2>/dev/null || true
	fi
	if [[ $push_rc -ne 0 ]]; then
		if _cas_push_rejection_is_protected_branch "$push_stderr"; then
			_cas_log_protected_branch_rejection
			_task_counter_status "unrecoverable_desync" "protected_counter_branch"
			return 1
		fi
		log_warn "Counter reconciliation push raced with another allocator; retrying allocation from refreshed branch"
		_task_counter_status "recovered_contention" "reconcile_raced"
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" fetch -q "$REMOTE_NAME" "$COUNTER_BRANCH" >/dev/null || true
		return 2
	fi
	return 0
}

# Re-fetch and reconcile a counter branch after CAS contention/desync.
#
# Normal CAS failures are retryable, but a non-main counter branch can become
# desynchronised with the repository's default branch (for example, develop has
# an older .task-counter than main after release/merge activity).  Before any
# fallback or fatal outcome, reconcile by pushing a counter-only commit on the
# configured counter branch with the maximum safe next-ID observed across:
#   - current counter branch
#   - default branch (when different and available)
#   - TODO.md seed (highest tNNN + 1)
#
# Returns:
#   0 — reconciliation pushed or branch already safe
#   1 — hard/unrecoverable desync (diagnostic emitted)
#   2 — race/contention while reconciling; caller may retry allocation
_cas_reconcile_counter_branch() {
	local repo_path="$1"
	local default_branch="${2:-main}"

	cd "$repo_path" || return 1
	_task_counter_status "reconciling" "branch=${REMOTE_NAME}/${COUNTER_BRANCH}"
	_cas_fetch_counter_branch_for_reconcile "$repo_path" || return 1

	local counter_ref="${REMOTE_NAME}/${COUNTER_BRANCH}"
	local pinned_sha=""
	pinned_sha=$(_cas_resolve_counter_ref_for_reconcile "$counter_ref") || return 1

	local branch_counter=""
	branch_counter=$(_cas_read_counter_file_from_ref "$pinned_sha" "$repo_path")

	local default_counter="0"
	default_counter=$(_cas_read_default_counter_for_reconcile "$default_branch")

	local reconciled_counter=""
	reconciled_counter=$(_cas_reconciled_counter_value "$repo_path" "$branch_counter" "$default_counter")

	if [[ "$reconciled_counter" == "$branch_counter" ]]; then
		_task_counter_status "recovered_contention" "refetched"
		return 0
	fi

	local tree_sha=""
	tree_sha=$(_cas_build_reconciled_counter_tree "$pinned_sha" "$reconciled_counter") || return 1
	local commit_sha=""
	commit_sha=$(_cas_create_reconciliation_commit "$pinned_sha" "$tree_sha" "$branch_counter" "$reconciled_counter") || return 1

	_cas_push_reconciliation_commit "$commit_sha" || return $?

	_task_counter_status "recovered_contention" "counter=${reconciled_counter}"
	_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" fetch -q "$REMOTE_NAME" "$COUNTER_BRANCH" >/dev/null || true
	return 0
}

# =============================================================================
# Machine-local mutex for CAS serialisation (Phase 2 / t2568 / GH#20001)
# =============================================================================
# macOS has no flock(1); use atomic mkdir as the lock primitive.
# Pattern mirrors pulse-instance-lock.sh (see reference/bash-fd-locking.md).
#
# Lock path: ~/.aidevops/locks/claim-task-id.<remote>.<branch>.lock/
# Shared across repos on the same host so local runners serialise on the
# same remote/branch — they are contending for the same .task-counter anyway.
#
# Bounded wait: poll for up to CAS_LOCAL_LOCK_TIMEOUT_S (default 10s).
# If the timeout elapses, fall through UNLOCKED — the git push is still the
# authoritative CAS gate and must never be blocked by the local mutex.
# =============================================================================

CAS_LOCAL_LOCK_DIR="${CAS_LOCAL_LOCK_DIR:-${HOME}/.aidevops/locks}"
CAS_LOCAL_LOCK_TIMEOUT_S="${CAS_LOCAL_LOCK_TIMEOUT_S:-10}"

# Return the path of the lock directory for the current remote+branch pair.
_cas_local_lock_path() {
	local safe_remote safe_branch
	safe_remote=$(printf '%s' "${REMOTE_NAME:-origin}" | tr -c 'A-Za-z0-9._-' '_')
	safe_branch=$(printf '%s' "${COUNTER_BRANCH:-main}" | tr -c 'A-Za-z0-9._-' '_')
	printf '%s/claim-task-id.%s.%s.lock' "$CAS_LOCAL_LOCK_DIR" "$safe_remote" "$safe_branch"
	return 0
}

# Attempt to acquire the local mutex within CAS_LOCAL_LOCK_TIMEOUT_S seconds.
# Returns: 0 — lock acquired, 1 — timeout elapsed (proceed unlocked).
# Stale-lock reclaim: if pid file points at a dead process the lock is cleared
# and acquisition is retried (mirrors pulse-instance-lock.sh pattern).
_cas_acquire_local_lock() {
	local lock_dir
	lock_dir=$(_cas_local_lock_path)
	mkdir -p "$CAS_LOCAL_LOCK_DIR" 2>/dev/null || true

	local deadline
	deadline=$(( $(date +%s) + CAS_LOCAL_LOCK_TIMEOUT_S ))

	while (( $(date +%s) < deadline )); do
		if mkdir "$lock_dir" 2>/dev/null; then
			printf '%s' "${BASHPID:-$$}" > "${lock_dir}/pid" 2>/dev/null || true
			return 0
		fi

		# Stale-lock reclaim: if pid file points at a dead process, remove
		# the lock dir and retry the mkdir on the next loop iteration.
		local lock_pid=""
		if [[ -r "${lock_dir}/pid" ]]; then
			lock_pid=$(cat "${lock_dir}/pid" 2>/dev/null || true)
		fi
		if [[ -n "$lock_pid" ]] && [[ "$lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
			rm -rf "$lock_dir" 2>/dev/null || true
			continue
		fi

		sleep 0.25
	done

	return 1
}

# Release the local mutex unconditionally.
_cas_release_local_lock() {
	local lock_dir
	lock_dir=$(_cas_local_lock_path)
	rm -rf "$lock_dir" 2>/dev/null || true
	return 0
}

# =============================================================================
# Counter Reads
# =============================================================================

# Get highest task ID from TODO.md content (used for migration only)
get_highest_task_id() {
	local todo_content="$1"
	local highest=0

	# Extract all task IDs (tNNN or tNNN.N format)
	while IFS= read -r line; do
		if [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[[[:space:]xX]\][[:space:]]t([0-9]+) ]]; then
			local task_num="${BASH_REMATCH[1]}"
			if ((10#$task_num > 10#$highest)); then
				highest="$task_num"
			fi
		fi
	done <<<"$todo_content"

	echo "$highest"
}

# Check if a task ID already appears in TODO.md (any status: active or completed).
# Used to detect .task-counter drift: IDs the counter thinks are unclaimed may
# already exist as historical TODO entries (GH#19454).
#
# Args:
#   $1 — numeric task ID without the "t" prefix (e.g. 2155, not "t2155")
#   $2 — repo path (default: current directory)
# Returns: 0 if the ID exists in TODO.md, 1 if not found
_id_exists_in_todo() {
	local id_num="$1"
	local repo_path="${2:-$PWD}"
	local todo_file="${repo_path}/TODO.md"

	[[ -f "$todo_file" ]] || return 1

	# Match "- [ ] tNNN" or "- [x] tNNN" (zero-padded variant included via 0*)
	if grep -qE "^[[:space:]]*-[[:space:]]\[[[:space:]xX]\][[:space:]]t0*${id_num}([[:space:]]|$)" "$todo_file"; then
		return 0
	fi

	return 1
}

# Compute seed value for .task-counter bootstrap from TODO.md (or default 1).
# Reads TODO.md from the repo root; falls back to 1 if not found or empty.
# Returns the seed value (highest task ID + 1, minimum 1).
_compute_counter_seed() {
	local repo_path="$1"
	local todo_file="${repo_path}/TODO.md"
	local seed=1

	if [[ -f "$todo_file" ]]; then
		local todo_content
		todo_content=$(cat "$todo_file" 2>/dev/null || true)
		if [[ -n "$todo_content" ]]; then
			local highest
			highest=$(get_highest_task_id "$todo_content")
			# Force base-10 (10#) so leading-zero IDs like "068" don't trip
			# bash's octal parser. Without this, repos that have any TODO entry
			# with t008-t009 or t08x-t09x ranges fail counter bootstrap with
			# "value too great for base (error token is "068")" on either the
			# -gt test below or the arithmetic on the next line.
			if [[ "$highest" =~ ^[0-9]+$ ]] && ((10#$highest > 0)); then
				seed=$((10#$highest + 1))
			fi
		fi
	fi

	echo "$seed"
	return 0
}

# =============================================================================
# Counter Bootstrap
# =============================================================================

# Bootstrap .task-counter on <remote>/<counter_branch> when it is missing.
# Seeds from TODO.md highest task ID (or 1 for fresh repos).
# Uses the same git plumbing as allocate_counter_cas to stay branch-safe.
# Returns 0 on success (counter now exists on remote), 1 on failure.
bootstrap_remote_counter() {
	local repo_path="$1"

	cd "$repo_path" || return 1

	log_info "BOOTSTRAP_COUNTER: .task-counter missing on ${REMOTE_NAME}/${COUNTER_BRANCH} — bootstrapping"

	local seed
	seed=$(_compute_counter_seed "$repo_path")
	log_info "BOOTSTRAP_COUNTER: seeding from TODO.md → counter=${seed}"

	# Create a blob with the seed value
	local blob_sha
	blob_sha=$(echo "$seed" | git hash-object -w --stdin 2>/dev/null) || {
		log_warn "BOOTSTRAP_COUNTER: failed to create blob"
		return 1
	}

	# Check whether .task-counter already exists in the remote tree
	local existing_tree
	existing_tree=$(git ls-tree "${REMOTE_NAME}/${COUNTER_BRANCH}" 2>/dev/null || true)

	local tree_sha
	if echo "$existing_tree" | grep -q "${COUNTER_FILE}$"; then
		# Replace existing (invalid) entry
		tree_sha=$(echo "$existing_tree" | sed "s|[0-9a-f]\{40,64\}	${COUNTER_FILE}$|${blob_sha}	${COUNTER_FILE}|" | git mktree 2>/dev/null) || {
			log_warn "BOOTSTRAP_COUNTER: failed to create tree (replace)"
			return 1
		}
	else
		# Add new entry to existing tree
		tree_sha=$(
			{
				echo "$existing_tree"
				printf '100644 blob %s\t%s\n' "$blob_sha" "$COUNTER_FILE"
			} | git mktree 2>/dev/null
		) || {
			log_warn "BOOTSTRAP_COUNTER: failed to create tree (add)"
			return 1
		}
	fi

	local parent_sha
	parent_sha=$(git rev-parse "${REMOTE_NAME}/${COUNTER_BRANCH}" 2>/dev/null) || {
		log_warn "BOOTSTRAP_COUNTER: failed to resolve ${REMOTE_NAME}/${COUNTER_BRANCH}"
		return 1
	}

	local commit_sha
	commit_sha=$(git commit-tree "$tree_sha" -p "$parent_sha" -m "chore: bootstrap .task-counter (seed=${seed})" 2>/dev/null) || {
		log_warn "BOOTSTRAP_COUNTER: failed to create commit"
		return 1
	}

	# GH#21904: wrap with timeout + SSH fallback for credential-helper hangs.
	if ! _run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		push "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" 2>/dev/null; then
		log_warn "BOOTSTRAP_COUNTER: push failed (conflict — another session may have bootstrapped)"
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null || true
		# Not a hard failure — the remote may now have a valid counter from the other session
		return 1
	fi

	_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null || true
	# yeah, the counter is seeded and ready for concurrent claims
	log_info "BOOTSTRAP_COUNTER_OK: counter initialized to ${seed} on ${REMOTE_NAME}/${COUNTER_BRANCH}"
	echo "BOOTSTRAP_COUNTER_OK"
	return 0
}

# Read .task-counter from <remote>/<counter_branch> (fetches first)
read_remote_counter() {
	local repo_path="$1"

	cd "$repo_path" || return 1

	# GH#21904: wrap with timeout + SSH fallback for credential-helper hangs.
	if ! _run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null; then
		log_warn "Failed to fetch ${REMOTE_NAME}/${COUNTER_BRANCH}"
		return 1
	fi

	local counter_value
	counter_value=$(git show "${REMOTE_NAME}/${COUNTER_BRANCH}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]')

	if [[ -z "$counter_value" ]] || ! [[ "$counter_value" =~ ^[0-9]+$ ]]; then
		log_warn "Invalid or missing ${COUNTER_FILE} on ${REMOTE_NAME}/${COUNTER_BRANCH}"
		return 1
	fi

	echo "$counter_value"
	return 0
}

# Read .task-counter from local working tree
read_local_counter() {
	local repo_path="$1"
	local counter_path="${repo_path}/${COUNTER_FILE}"

	if [[ ! -f "$counter_path" ]]; then
		log_warn "${COUNTER_FILE} not found at: $counter_path"
		return 1
	fi

	local counter_value
	counter_value=$(tr -d '[:space:]' <"$counter_path")

	if [[ -z "$counter_value" ]] || ! [[ "$counter_value" =~ ^[0-9]+$ ]]; then
		log_warn "Invalid ${COUNTER_FILE} content: $counter_value"
		return 1
	fi

	echo "$counter_value"
	return 0
}

# =============================================================================
# CAS (Compare-And-Swap) Plumbing
# =============================================================================

# Fetch remote counter branch and pin the commit SHA for atomic reads.
# CRITICAL (GH#19689): all subsequent reads in the CAS function MUST use
# the pinned SHA, never the ref name. When concurrent processes share a
# repo, a competing push+fetch can update the local ref between our
# counter-read and our tree/parent-read, breaking the CAS invariant.
#
# Echoes "pinned_sha counter_value" on success. Returns 1 on failure.
_cas_fetch_and_pin() {
	local repo_path="$1"

	cd "$repo_path" || return 1

	# GH#20137: set git-native HTTP timeouts to prevent indefinite hangs.
	# http.lowSpeedLimit=1000 + http.lowSpeedTime=CAS_GIT_CMD_TIMEOUT_S
	# tells git to abort if HTTP transfer drops below 1KB/s for N seconds.
	# These only affect HTTP(S) transport; local/SSH transports don't hang on
	# network I/O.  index.lock contention is caught by the wall-clock timeout
	# in allocate_online().  Pass via -c so git actually reads them (env vars
	# GIT_HTTP_LOW_SPEED_LIMIT/TIME are not recognised by git).
	# GH#20208: redirect stdout to /dev/null (see _cas_build_and_push for details).
	# GH#21904: wrap with `timeout_sec` + SSH fallback to defeat credential-helper
	# hangs that fire BEFORE bytes flow (osxkeychain etc.) and so bypass
	# http.lowSpeedTime.
	if ! _run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		-c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
		fetch -q "$REMOTE_NAME" "$COUNTER_BRANCH" >/dev/null; then
		log_warn "Failed to fetch ${REMOTE_NAME}/${COUNTER_BRANCH}"
	fi

	local pinned_sha
	pinned_sha=$(git rev-parse "${REMOTE_NAME}/${COUNTER_BRANCH}" 2>/dev/null) || {
		log_warn "Failed to resolve ${REMOTE_NAME}/${COUNTER_BRANCH}"
		return 1
	}

	local current_value
	current_value=$(git show "${pinned_sha}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]')

	if [[ -z "$current_value" ]] || ! [[ "$current_value" =~ ^[0-9]+$ ]]; then
		log_info "Counter missing/invalid — attempting auto-bootstrap (GH#6569)"
		local bootstrap_result
		bootstrap_result=$(bootstrap_remote_counter "$repo_path") || true
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			-c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
			fetch -q "$REMOTE_NAME" "$COUNTER_BRANCH" >/dev/null || true
		pinned_sha=$(git rev-parse "${REMOTE_NAME}/${COUNTER_BRANCH}" 2>/dev/null) || {
			log_error "BOOTSTRAP_COUNTER_FAILED: cannot resolve ref after bootstrap"
			return 1
		}
		current_value=$(git show "${pinned_sha}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]')
		if [[ -z "$current_value" ]] || ! [[ "$current_value" =~ ^[0-9]+$ ]]; then
			log_error "BOOTSTRAP_COUNTER_FAILED: counter unavailable after bootstrap attempt"
			return 1
		fi
	fi

	echo "${pinned_sha} ${current_value}"
	return 0
}

# Build a counter-increment commit on top of pinned_sha and push it.
# Uses git plumbing (hash-object, ls-tree, mktree, commit-tree) — safe
# from any branch, never touches HEAD or the working tree index.
# All reads use pinned_sha to prevent the ref-race (GH#19689).
#
# Returns 0 on success, 1 on hard error, 2 on retriable conflict.
_cas_build_and_push() {
	local pinned_sha="$1"
	local new_counter="$2"
	local commit_msg="$3"

	local blob_sha
	blob_sha=$(echo "$new_counter" | git hash-object -w --stdin 2>/dev/null) || {
		log_warn "Failed to create blob"
		return 1
	}

	local tree_sha
	tree_sha=$(git ls-tree "${pinned_sha}" | sed "s|[0-9a-f]\{40,64\}	${COUNTER_FILE}$|${blob_sha}	${COUNTER_FILE}|" | git mktree 2>/dev/null) || {
		log_warn "Failed to create tree"
		return 1
	}

	local commit_sha
	commit_sha=$(git commit-tree "$tree_sha" -p "$pinned_sha" -m "$commit_msg" 2>/dev/null) || {
		log_warn "Failed to create commit"
		return 1
	}

	# GH#20137: set git-native HTTP timeouts to prevent indefinite hangs on slow
	# networks.  index.lock contention is caught by the wall-clock timeout in
	# allocate_online().  Pass via -c so git actually reads them (env vars
	# GIT_HTTP_LOW_SPEED_LIMIT/TIME are not recognised by git).
	#
	# GH#20208: redirect stdout to /dev/null. `git push -q` suppresses git's
	# own progress output, but it does NOT suppress stdout from any pre-push
	# hooks that git invokes. When _cas_build_and_push runs inside a command
	# substitution (allocate_counter_cas → $(...)), any hook stdout bleeds
	# into the captured result and poisons downstream arithmetic parsing.
	# Hook stderr stays visible for error diagnosis.
	#
	# GH#21904: wrap with `timeout_sec` + SSH fallback so an HTTPS credential-
	# helper hang (osxkeychain etc.) cannot stall the push.  The SSH fallback
	# returns the same exit codes as a direct push, so the conflict (rc=1)
	# vs success (rc=0) handling below is unchanged.
	local push_rc=0
	local push_stderr=""
	local push_err_file=""
	push_err_file=$(mktemp "${TMPDIR:-/tmp}/claim-task-id-push.XXXXXX" 2>/dev/null) || push_err_file=""
	if [[ -n "$push_err_file" ]]; then
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			-c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
			push -q "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" >/dev/null 2>"$push_err_file" || push_rc=$?
		push_stderr=$(<"$push_err_file")
		rm -f "$push_err_file" 2>/dev/null || true
	else
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			-c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
			push -q "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" >/dev/null || push_rc=$?
	fi
	if [[ $push_rc -ne 0 ]]; then
		if _cas_push_rejection_is_protected_branch "$push_stderr"; then
			_cas_log_protected_branch_rejection
			return "$CAS_PROTECTED_BRANCH_RC"
		fi
		if [[ $push_rc -eq 124 ]]; then
			log_warn "Push timed out (HTTPS + SSH fallback both unavailable) — treating as retriable conflict"
		else
			log_warn "Push failed (conflict — another session claimed an ID)"
		fi
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			-c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
			fetch -q "$REMOTE_NAME" "$COUNTER_BRANCH" >/dev/null || true
		return 2
	fi

	_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		-c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
		fetch -q "$REMOTE_NAME" "$COUNTER_BRANCH" >/dev/null || true
	return 0
}

# =============================================================================
# Allocation Functions
# =============================================================================

# Atomic CAS allocation: fetch → read → increment → commit → push
# Returns 0 on success, 1 on hard error, 2 on retriable conflict, and
# CAS_PROTECTED_BRANCH_RC when repository policy rejects direct pushes.
allocate_counter_cas() {
	local repo_path="$1"
	local count="$2"

	cd "$repo_path" || return 1

	# Step 1: Fetch + pin (atomic snapshot of counter + parent SHA)
	local pin_result
	pin_result=$(_cas_fetch_and_pin "$repo_path") || return 1
	local pinned_sha current_value
	pinned_sha="${pin_result%% *}"
	current_value="${pin_result##* }"

	local first_id="$current_value"
	local last_id=$((current_value + count - 1))
	local new_counter=$((current_value + count))

	local id_range
	id_range=$(_format_task_range "$first_id" "$last_id")
	log_info "Counter at ${current_value}, claiming ${id_range}, new counter: ${new_counter}"

	# Per-process nonce prevents commit-identity collision (GH#19689 root cause #2).
	# git commit-tree is content-addressed: identical inputs (tree, parent, message,
	# timestamp) produce identical SHA. Concurrent processes in the same second all
	# produce the same SHA, and git push returns 0 ("Everything up-to-date") for
	# duplicates — the CAS gate silently passes. The nonce (PID + random) makes
	# each process's commit unique.
	local nonce="${BASHPID:-$$}_${RANDOM}"

	local commit_msg="chore: claim task ID"
	if [[ "$count" -eq 1 ]]; then
		commit_msg="chore: claim $(printf 't%03d' "$first_id") [${nonce}]"
	else
		commit_msg="chore: claim $(_format_task_range "$first_id" "$last_id") [${nonce}]"
	fi

	# Step 2+3: Build commit on pinned_sha and push (atomic gate)
	_cas_build_and_push "$pinned_sha" "$new_counter" "$commit_msg" || return $?

	# Success — output the claimed IDs
	echo "$first_id"
	return 0
}

# Online allocation with CAS retry loop.
# GH#20137: enforces a wall-clock timeout (CAS_WALL_TIMEOUT_S, default 30s)
# in addition to the retry count.  Under concurrent-worker contention, each
# git fetch/push can take several seconds due to index.lock waits; without
# a wall-clock cap the loop could run for 180s+ (30 retries × 6s each).
# The backoff is capped at 2.0s to keep retries tight within the budget.
#
# Phase 2 (t2568 / GH#20001): machine-local mutex wraps the retry loop to
# serialise concurrent agents on the same host.  Lock acquisition failure is
# non-fatal — the git push remains the authoritative CAS gate.
allocate_online() {
	local repo_path="$1"
	local count="$2"
	local attempt=0
	local first_id=""
	local start_epoch
	start_epoch=$(date +%s)

	# Phase 2 (t2568 / GH#20001): machine-local mutex.
	# Acquire before entering the retry loop so local runners serialise at the
	# fetch→read→build→push boundary.  Fail-open: if lock times out, log a
	# warning and proceed unlocked — the git push is still the CAS authority.
	local _have_local_lock=0
	if _cas_acquire_local_lock; then
		_have_local_lock=1
	else
		log_warn "Could not acquire local CAS mutex within ${CAS_LOCAL_LOCK_TIMEOUT_S}s — proceeding unlocked (git push remains authoritative)"
	fi

	# shellcheck disable=SC2064  # intentional: flag captured at definition time
	trap "[[ \${_have_local_lock:-0} -eq 1 ]] && _cas_release_local_lock; trap - RETURN" RETURN

	while [[ $attempt -lt $CAS_MAX_RETRIES ]]; do
		# GH#20137: wall-clock timeout — abort if we've exceeded CAS_WALL_TIMEOUT_S
		local now_epoch
		now_epoch=$(date +%s)
		local elapsed=$(( now_epoch - start_epoch ))
		if [[ $elapsed -ge $CAS_WALL_TIMEOUT_S ]]; then
			log_error "CAS wall-clock timeout after ${elapsed}s (limit=${CAS_WALL_TIMEOUT_S}s, attempt=${attempt}/${CAS_MAX_RETRIES})"
			return 1
		fi

		attempt=$((attempt + 1))

		if [[ $attempt -gt 1 ]]; then
			log_info "Retry attempt ${attempt}/${CAS_MAX_RETRIES} (${elapsed}s elapsed)..."
			# Exponential-ish backoff: 0.1s * attempt + jitter, CAPPED at 2.0s.
			# The cap prevents late retries from consuming too much of the wall-clock
			# budget (GH#20137).  Previous uncapped backoff at attempt 30 was ~3.3s,
			# leaving <7s for the actual git operations.
			local jitter_ms=$((RANDOM % 300))
			local backoff
			backoff=$(awk "BEGIN {v=$attempt * 0.1 + $jitter_ms / 1000; printf \"%.1f\", (v > 2.0 ? 2.0 : v)}")
			sleep "$backoff" 2>/dev/null || true
		fi

		local cas_result=0
		first_id=$(allocate_counter_cas "$repo_path" "$count") || cas_result=$?

		case $cas_result in
		0)
			# go for it — CAS succeeded on this attempt
			log_success "Claimed $(printf 't%03d' "$first_id") (attempt ${attempt}, ${elapsed}s)"
			# Phase 3 (t2569 / GH#20001): structured audit log.
			_append_claim_audit_log "$first_id" "$attempt" "$elapsed"
			_task_coordinator_shadow_legacy "$first_id" "$count"
			echo "$first_id"
			return 0
			;;
		2)
			# Retriable conflict — loop continues
			continue
			;;
		"$CAS_PROTECTED_BRANCH_RC")
			# Policy rejection — preserve the distinct setup-error result so
			# higher layers do not run contention reconciliation and retry.
			return "$CAS_PROTECTED_BRANCH_RC"
			;;
		*)
			log_error "Hard error during allocation"
			return 1
			;;
		esac
	done

	log_error "Failed to allocate after ${CAS_MAX_RETRIES} attempts"
	return 1
}

# Online allocation with TODO.md historical-collision avoidance (GH#19454).
# Wraps allocate_online() with a skip-and-retry loop: when the CAS claims an ID
# that already appears in TODO.md (completed or active), the counter has already
# been advanced past it — log the skip and retry with the next ID.
#
# Each skip burns one CAS commit (a git push). Defensive cap: 100 sequential
# skips abort with an error requiring manual counter repair.
#
# Args:
#   $1 — repo_path
#   $2 — count (number of consecutive IDs to allocate)
# Returns:
#   0 — first clean first_id echoed to stdout
#   1 — hard error (allocation failed or 100-skip cap exceeded)
#   CAS_PROTECTED_BRANCH_RC — direct counter pushes are forbidden by policy
_allocate_online_with_collision_check() {
	local repo_path="$1"
	local count="$2"
	local max_skips=100
	local total_skips=0

	while true; do
		local first_id=""
		local allocation_rc=0
		first_id=$(allocate_online "$repo_path" "$count") || allocation_rc=$?
		if [[ $allocation_rc -ne 0 ]]; then
			return "$allocation_rc"
		fi

		# Check every ID in the batch against TODO.md
		local collision_id=""
		local i
		for ((i = 0; i < count; i++)); do
			local check_id=$((first_id + i))
			if _id_exists_in_todo "$check_id" "$repo_path"; then
				collision_id="$check_id"
				break
			fi
		done

		if [[ -z "$collision_id" ]]; then
			echo "$first_id"
			return 0
		fi

		total_skips=$((total_skips + 1))
		log_info "TODO.md collision: t$(printf '%03d' "$collision_id") already exists — skipping (${total_skips}/${max_skips})"

		if [[ $total_skips -ge $max_skips ]]; then
			log_error "TODO.md collision guard: exhausted ${max_skips} skip attempts"
			log_error ".task-counter is severely out of sync with TODO.md"
			log_error "Manual fix: check TODO.md and .task-counter on ${REMOTE_NAME}/${COUNTER_BRANCH}"
			return 1
		fi
	done
}

# Offline allocation (with safety offset)
# Falls back to TODO.md seed when local .task-counter is missing (GH#6569).
allocate_offline() {
	local repo_path="$1"
	local count="$2"

	log_warn "Using offline mode with +${OFFLINE_OFFSET} offset"

	local current_value
	if ! current_value=$(read_local_counter "$repo_path"); then
		# Auto-bootstrap local counter from TODO.md (GH#6569)
		log_warn "Local ${COUNTER_FILE} missing — bootstrapping from TODO.md for offline use"
		local seed
		seed=$(_compute_counter_seed "$repo_path")
		log_info "BOOTSTRAP_COUNTER: offline seed from TODO.md → ${seed}"
		echo "$seed" >"${repo_path}/${COUNTER_FILE}"
		current_value="$seed"
		log_info "BOOTSTRAP_COUNTER_OK: local counter initialized to ${seed}"
	fi

	local first_id=$((current_value + OFFLINE_OFFSET))
	local last_id=$((first_id + count - 1))
	local new_counter=$((first_id + count))

	# Update local counter and commit locally (no push).
	# GH#20137: previous version left .task-counter dirty in the working tree.
	# Committing locally ensures clean working tree and survives session
	# interruption.  Reconciliation still required when back online.
	echo "$new_counter" >"${repo_path}/${COUNTER_FILE}"
	(
		cd "$repo_path" || exit 1
		git add "$COUNTER_FILE" || true
		GIT_AUTHOR_NAME="aidevops" GIT_AUTHOR_EMAIL="aidevops@local" \
		GIT_COMMITTER_NAME="aidevops" GIT_COMMITTER_EMAIL="aidevops@local" \
		git commit -q -m "chore: offline claim $(_format_task_range "$first_id" "$last_id") [offline]" \
			--no-verify --no-gpg-sign "$COUNTER_FILE" || true
	)

	log_warn "Allocated $(printf 't%03d' "$first_id") with offset (reconcile when back online)"

	echo "$first_id"
	return 0
}
