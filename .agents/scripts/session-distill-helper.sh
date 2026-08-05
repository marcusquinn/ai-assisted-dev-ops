#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Session Distill Helper - Extract learnings from session for memory storage
# =============================================================================
# Analyzes session context and extracts valuable learnings to store in memory.
# Integrates with /session-review and memory-helper.sh.
#
# Usage:
#   session-distill-helper.sh analyze           # Analyze current session context
#   session-distill-helper.sh extract           # Extract and format learnings
#   session-distill-helper.sh propose [file]    # Persist privacy-scanned proposals
#   session-distill-helper.sh finalize          # Resume eligible proposal finalization
#   session-distill-helper.sh provenance [...]  # Capture authoritative git provenance
#   session-distill-helper.sh auto              # Persist checkpoint, then print a compact receipt
#
# Integration:
#   - Called by /session-review at end of sessions
#   - Uses memory-helper.sh for storage
#   - Reads git history, TODO.md changes, and session patterns
# =============================================================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly SCRIPT_DIR
readonly MEMORY_HELPER="$SCRIPT_DIR/memory-helper.sh"
readonly WORKSPACE_DIR="${AIDEVOPS_WORKSPACE:-$HOME/.aidevops/.agent-workspace}"
readonly SESSION_DIR="$WORKSPACE_DIR/sessions"
# shellcheck disable=SC2034  # Reserved for future use
readonly DISTILL_OUTPUT="$SESSION_DIR/distill-output.json"

_distill_sha256_stdin() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | cut -d' ' -f1 || return 1
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum | cut -d' ' -f1 || return 1
	elif command -v python3 >/dev/null 2>&1; then
		python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' || return 1
	else
		log_error "No SHA-256 implementation is available"
		return 1
	fi
	return 0
}

# Build a private, deterministic local identifier when the runtime provides no
# session ID. This is collision isolation, not authentication; SHA-256 prevents
# the repository path from being exposed while avoiding weak-hash scanners.
_distill_fallback_session_id() {
	local repository_root=""
	local branch=""
	local root_hash=""
	repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || repository_root=$(pwd -P)
	branch=$(git branch --show-current 2>/dev/null) || branch=""
	[[ -n "$branch" ]] || branch="unknown"

	root_hash=$(printf '%s' "$repository_root" | _distill_sha256_stdin) || return 1
	root_hash="${root_hash:0:12}"

	printf '%s-%s' "$root_hash" "$branch"
	return 0
}

readonly SESSION_ID="${AIDEVOPS_SESSION_ID:-${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-$(_distill_fallback_session_id)}}}"
readonly SAFE_SESSION_ID="${SESSION_ID//[^a-zA-Z0-9_.-]/_}"
readonly SESSION_STATE_DIR="$SESSION_DIR/$SAFE_SESSION_ID"
readonly PROPOSALS_FILE="$SESSION_STATE_DIR/observation-proposals.json"
readonly PROVENANCE_FILE="$SESSION_STATE_DIR/git-provenance.json"
readonly DISTILL_STATUS_NONE="none"
readonly DISTILL_STATUS_NOT_RUN="not-run"
readonly DISTILL_PROPOSAL_PENDING="pending_review"

# shellcheck disable=SC2034  # Available for future use

# Logging: uses shared log_* from shared-constants.sh

#######################################
# Ensure session directory exists
#######################################
init_session_dir() {
	mkdir -p "$SESSION_STATE_DIR"
	return 0
}

privacy_redact() {
	local text="$1"
	text=$(printf '%s' "$text" | sed -E 's|/Users/[^ ]*|[local-path]|g; s|/home/[^ ]*|[local-path]|g; s|/private/var/[^ ]*|[local-path]|g; s|/var/folders/[^ ]*|[local-path]|g; s|~/Git/[^ ]*|[local-path]|g')
	text=$(printf '%s' "$text" | sed -E 's/(^|[^A-Za-z0-9_-])(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/\1[redacted-credential]/g')
	text=$(printf '%s' "$text" | sed -E 's/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/[email]/g')
	printf '%s' "$text"
	return 0
}

atomic_write_json() {
	local target="$1"
	local content="$2"
	local temporary="${target}.tmp.$$"
	printf '%s\n' "$content" >"$temporary"
	mv "$temporary" "$target"
	return 0
}

capture_git_provenance() {
	local repository=""
	local pr_number=""
	local worktree=""
	local branch=""
	local head_commit=""
	local merge_commit=""
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--repo) repository="${2:-}"; shift 2 ;;
		--pr) pr_number="${2:-}"; shift 2 ;;
		--worktree) worktree="${2:-}"; shift 2 ;;
		--branch) branch="${2:-}"; shift 2 ;;
		--commit) head_commit="${2:-}"; shift 2 ;;
		*) log_error "Unknown provenance option: $option"; return 1 ;;
		esac
	done

	if [[ -n "$pr_number" && ! "$pr_number" =~ ^[0-9]+$ ]]; then
		log_error "--pr must be numeric"
		return 1
	fi
	repository=$(printf '%s' "$repository" | tr '[:upper:]' '[:lower:]')
	repository="${repository%.git}"
	if [[ -z "$repository" && -n "$worktree" && -d "$worktree" ]]; then
		repository=$(repository_slug_for_path "$worktree")
	fi
	if [[ -z "$repository" ]]; then
		log_warn "Authoritative repository attribution is unavailable; provenance was not recorded"
		return 1
	fi
	if [[ -z "$head_commit" && -n "$worktree" && -d "$worktree" ]]; then
		head_commit=$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)
	fi
	if [[ -z "$branch" && -n "$worktree" && -d "$worktree" ]]; then
		branch=$(git -C "$worktree" branch --show-current 2>/dev/null || true)
	fi
	if [[ -n "$pr_number" && -n "$repository" ]] && command -v gh >/dev/null 2>&1; then
		local pr_json=""
		pr_json=$(gh pr view "$pr_number" --repo "$repository" --json mergeCommit,headRefOid,headRefName 2>/dev/null || true)
		if printf '%s' "$pr_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
			merge_commit=$(printf '%s' "$pr_json" | jq -r '.mergeCommit.oid // empty')
			[[ -n "$head_commit" ]] || head_commit=$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty')
			[[ -n "$branch" ]] || branch=$(printf '%s' "$pr_json" | jq -r '.headRefName // empty')
		fi
	fi

	local commit="$head_commit"
	[[ "$commit" =~ ^[0-9a-fA-F]{40}$ ]] || commit="$merge_commit"
	if [[ ! "$commit" =~ ^[0-9a-fA-F]{40}$ ]]; then
		log_warn "Authoritative commit attribution is unavailable; provenance was not recorded"
		return 1
	fi

	init_session_dir
	local safe_worktree=""
	safe_worktree=$(privacy_redact "$worktree")
	local existing='[]'
	[[ -f "$PROVENANCE_FILE" ]] && existing=$(jq -c '.items // []' "$PROVENANCE_FILE" 2>/dev/null || printf '[]')
	local key=""
	key=$(printf '%s\0%s\0%s\0%s' "$SESSION_ID" "$repository" "$pr_number" "$head_commit" | _distill_sha256_stdin) || return 1
	if printf '%s' "$existing" | jq -e --arg key "$key" 'any(.[]; .idempotency_key == $key)' >/dev/null; then
		local enriched=""
		enriched=$(printf '%s' "$existing" | jq -c --arg key "$key" --arg merge_commit "$merge_commit" \
			'map(if .idempotency_key == $key and $merge_commit != "" then .merge_commit = $merge_commit else . end)')
		local enriched_ledger=""
		enriched_ledger=$(printf '%s' "$enriched" | jq -c --arg session "$SESSION_ID" \
			'{schema_version:1,session_boundary:$session,items:.}')
		atomic_write_json "$PROVENANCE_FILE" "$enriched_ledger"
		return 0
	fi
	local item=""
	item=$(jq -n --arg key "$key" --arg repo "$repository" --arg pr "$pr_number" --arg commit "$commit" \
		--arg head_commit "$head_commit" --arg merge_commit "$merge_commit" \
		--arg branch "$branch" --arg worktree "$safe_worktree" --arg captured_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
		'{idempotency_key:$key,repository:$repo,pr_number:$pr,commit:$commit,head_commit:$head_commit,merge_commit:$merge_commit,branch:$branch,worktree:$worktree,captured_at:$captured_at}')
	local ledger=""
	ledger=$(printf '%s' "$existing" | jq -c --arg session "$SESSION_ID" --argjson item "$item" \
		'{schema_version:1,session_boundary:$session,items:(. + [$item])}')
	atomic_write_json "$PROVENANCE_FILE" "$ledger"
	log_success "Session git provenance captured"
	return 0
}

repository_slug_for_path() {
	local repository_path="$1"
	local remote_url=""
	remote_url=$(git -C "$repository_path" remote get-url origin 2>/dev/null || true)
	case "$remote_url" in
	git@*:*/*) remote_url="${remote_url#*:}" ;;
	ssh://*/*/* | http://*/*/* | https://*/*/*)
		remote_url="${remote_url#*://}"
		remote_url="${remote_url#*/}"
		;;
	*) remote_url="" ;;
	esac
	remote_url="${remote_url%.git}"
	printf '%s\n' "$remote_url" | tr '[:upper:]' '[:lower:]'
	return 0
}

resolve_provenance_item() {
	local item="$1"
	local current_repository="$2"
	local item_repository=""
	item_repository=$(printf '%s' "$item" | jq -r '.repository // empty')
	if [[ -z "$current_repository" || -z "$item_repository" || "$item_repository" != "$current_repository" ]]; then
		return 1
	fi
	local candidate=""
	while IFS= read -r candidate; do
		[[ "$candidate" =~ ^[0-9a-fA-F]{40}$ ]] || continue
		if git cat-file -e "${candidate}^{commit}" 2>/dev/null; then
			printf '%s' "$item" | jq -c --arg commit "$candidate" '.commit = $commit'
			return 0
		fi
	done < <(printf '%s' "$item" | jq -r '.head_commit // .commit // empty, .merge_commit // empty')
	return 1
}

session_provenance_items() {
	[[ -f "$PROVENANCE_FILE" ]] || {
		printf '[]\n'
		return 0
	}
	local current_repository=""
	current_repository=$(repository_slug_for_path ".")
	local item=""
	local resolved_items=""
	resolved_items=$(while IFS= read -r item; do
		resolve_provenance_item "$item" "$current_repository" || true
	done < <(jq -c '.items[]?' "$PROVENANCE_FILE" 2>/dev/null) | jq -sc '.')
	printf '%s\n' "$resolved_items"
	return 0
}

provenance_commit_messages() {
	local items="$1"
	local commit=""
	while IFS= read -r commit; do
		[[ -n "$commit" ]] || continue
		git show -s --format='%s' "$commit" 2>/dev/null || true
	done < <(printf '%s' "$items" | jq -r '.[].commit')
	return 0
}

#######################################
# Analyze current session context
# Gathers data from git, TODO.md, and recent activity
#######################################
analyze_session() {
	init_session_dir

	log_info "Analyzing session context..."

	local analysis_file="$SESSION_STATE_DIR/session-analysis.json"

	# Gather only session-bound git context. The current checkout is not evidence:
	# after worktree cleanup it may be canonical main at unrelated later commits.
	local provenance_items branch commits_today files_changed attribution_status
	provenance_items=$(session_provenance_items)
	commits_today=$(printf '%s' "$provenance_items" | jq 'length')
	branch=$(printf '%s' "$provenance_items" | jq -r 'last.branch // "unavailable"')
	attribution_status="authoritative"
	[[ "$commits_today" -gt 0 ]] || attribution_status="unavailable"
	files_changed=0
	local provenance_commit=""
	while IFS= read -r provenance_commit; do
		[[ -n "$provenance_commit" ]] || continue
		local changed_count=0
		changed_count=$(git diff-tree --no-commit-id --name-only -r "$provenance_commit" 2>/dev/null | wc -l | tr -d ' ') || changed_count=0
		files_changed=$((files_changed + changed_count))
	done < <(printf '%s' "$provenance_items" | jq -r '.[].commit')

	local recent_commits
	recent_commits=$(provenance_commit_messages "$provenance_items")
	if [[ "$attribution_status" == "unavailable" ]]; then
		log_warn "Authoritative session commit attribution is unavailable; current-branch commits were excluded"
	fi

	# Check for error patterns in recent commits
	local error_fixes
	error_fixes=$(echo "$recent_commits" | grep -ci "fix\|error\|bug\|issue" || true)
	[[ -z "$error_fixes" ]] && error_fixes=0

	# Check TODO.md for completed tasks
	local completed_tasks
	if [[ -f "TODO.md" ]]; then
		completed_tasks=$(grep -c "^\- \[x\]" TODO.md 2>/dev/null || true)
		[[ -z "$completed_tasks" ]] && completed_tasks=0
	else
		completed_tasks="0"
	fi

	# Build analysis JSON safely using jq to prevent JSON injection
	jq -n \
		--arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
		--arg branch "$branch" \
		--arg attribution_status "$attribution_status" \
		--argjson commits_today "$commits_today" \
		--argjson files_changed "$files_changed" \
		--argjson error_fixes "$error_fixes" \
		--argjson completed_tasks "$completed_tasks" \
		--arg recent_commits "$recent_commits" \
		--argjson provenance "$provenance_items" \
		'{
            timestamp: $timestamp,
            branch: $branch,
			commit_attribution: $attribution_status,
			provenance: $provenance,
            commits_today: $commits_today,
            files_changed: $files_changed,
            error_fixes: $error_fixes,
            completed_tasks: $completed_tasks,
            recent_commits: ($recent_commits | split("\n") | map(select(length > 0)))
        }' >"$analysis_file"

	log_success "Session analysis saved to $analysis_file"
	cat "$analysis_file"
	return 0
}

#######################################
# Extract learnings from session
# Identifies patterns worth remembering
#######################################
extract_learnings() {
	init_session_dir

	log_info "Extracting learnings from session..."

	local analysis_file="$SESSION_STATE_DIR/session-analysis.json"
	local learnings_file="$SESSION_STATE_DIR/extracted-learnings.json"

	if [[ ! -f "$analysis_file" ]]; then
		log_warn "No session analysis found. Running analyze first..."
		analyze_session
	fi

	# Read analysis
	local branch commits_today error_fixes
	branch=$(jq -r '.branch' "$analysis_file" 2>/dev/null || echo "unknown")
	commits_today=$(jq -r '.commits_today' "$analysis_file" 2>/dev/null || echo "0")
	error_fixes=$(jq -r '.error_fixes' "$analysis_file" 2>/dev/null || echo "0")

	# Extract learnings based on patterns
	local learnings=()

	# Pattern 1: Error fixes → WORKING_SOLUTION or ERROR_FIX
	if [[ "$error_fixes" -gt 0 ]]; then
		# Get the fix commit messages
		local fix_commits
		fix_commits=$(jq -r '[.recent_commits[]? | select(test("fix|error|bug"; "i"))] | .[:3][]' "$analysis_file" || echo "")

		if [[ -n "$fix_commits" ]]; then
			while IFS= read -r commit_msg; do
				if [[ -n "$commit_msg" ]]; then
					# Use jq to safely build JSON and prevent injection
					local learning_json
					learning_json=$(jq -n --arg type "ERROR_FIX" --arg content "$commit_msg" --arg tags "session,auto-distill,$branch" \
						'{type: $type, content: $content, tags: $tags}')
					learnings+=("$learning_json")
				fi
			done <<<"$fix_commits"
		fi
	fi

	# Pattern 2: Feature branch completion → WORKING_SOLUTION
	if [[ "$branch" == feature/* ]] && [[ "$commits_today" -gt 2 ]]; then
		local feature_name="${branch#feature/}"
		local learning_json
		learning_json=$(jq -n --arg type "WORKING_SOLUTION" --arg content "Implemented feature: $feature_name" --arg tags "session,feature,$feature_name" \
			'{type: $type, content: $content, tags: $tags}')
		learnings+=("$learning_json")
	fi

	# Pattern 3: Refactor patterns → CODEBASE_PATTERN
	local refactor_commits
	refactor_commits=$(jq -r '[.recent_commits[]? | select(test("refactor|restructure|reorganize"; "i"))] | .[:2][]' "$analysis_file" || echo "")
	if [[ -n "$refactor_commits" ]]; then
		while IFS= read -r commit_msg; do
			if [[ -n "$commit_msg" ]]; then
				local learning_json
				learning_json=$(jq -n --arg type "CODEBASE_PATTERN" --arg content "$commit_msg" --arg tags "session,refactor,$branch" \
					'{type: $type, content: $content, tags: $tags}')
				learnings+=("$learning_json")
			fi
		done <<<"$refactor_commits"
	fi

	# Pattern 4: Documentation updates → CONTEXT
	local doc_commits
	doc_commits=$(jq -r '[.recent_commits[]? | select(test("doc|readme|comment"; "i"))] | .[:2][]' "$analysis_file" || echo "")
	if [[ -n "$doc_commits" ]]; then
		while IFS= read -r commit_msg; do
			if [[ -n "$commit_msg" ]]; then
				local learning_json
				learning_json=$(jq -n --arg type "CONTEXT" --arg content "$commit_msg" --arg tags "session,documentation,$branch" \
					'{type: $type, content: $content, tags: $tags}')
				learnings+=("$learning_json")
			fi
		done <<<"$doc_commits"
	fi

	# Build learnings JSON safely without string concatenation
	if [[ ${#learnings[@]} -eq 0 ]]; then
		printf '%s\n' '[]' >"$learnings_file"
	else
		printf '%s\n' "${learnings[@]}" | jq -s '.' >"$learnings_file"
	fi

	local count
	count=$(jq 'length' "$learnings_file")
	log_success "Extracted $count learnings to $learnings_file"

	cat "$learnings_file"
	return 0
}

#######################################
# Persist extracted observations as resumable proposals
#######################################
propose_learnings() {
	local input_file="${1:-$SESSION_STATE_DIR/extracted-learnings.json}"
	init_session_dir
	if [[ ! -f "$input_file" ]]; then
		log_warn "No extracted learnings found. Running extract first..."
		extract_learnings
	fi
	local source_boundary
	source_boundary=$(privacy_redact "${AIDEVOPS_OBSERVATION_SOURCE:-git:$PWD}")
	local existing='[]'
	[[ -f "$PROPOSALS_FILE" ]] && existing=$(jq -c '.items // []' "$PROPOSALS_FILE")
	local proposed="$existing"
	while IFS= read -r learning; do
		local type content tags explicit risk key item now
		type=$(printf '%s' "$learning" | jq -r '.type // "CONTEXT"')
		content=$(privacy_redact "$(printf '%s' "$learning" | jq -r '.content // empty')")
		tags=$(printf '%s' "$learning" | jq -r '.tags // "session,proposal"')
		explicit=$(printf '%s' "$learning" | jq -r '.explicit // false')
		risk=$(printf '%s' "$learning" | jq -r '.risk // "consequential"')
		[[ -z "$content" ]] && continue
		key=$(printf '%s\0%s\0%s\0%s' "$SESSION_ID" "$source_boundary" "$type" "$content" | shasum -a 256 | cut -d' ' -f1)
		if printf '%s' "$proposed" | jq -e --arg key "$key" 'any(.[]; .idempotency_key == $key)' >/dev/null; then
			continue
		fi
		now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
		item=$(jq -n --arg key "$key" --arg source "$source_boundary" --arg type "$type" --arg content "$content" --arg tags "$tags" --arg risk "$risk" --arg now "$now" --arg pending "$DISTILL_PROPOSAL_PENDING" --argjson explicit "$explicit" '{idempotency_key:$key,source_boundary:$source,type:$type,content:$content,tags:$tags,explicit:$explicit,risk:$risk,state:$pending,created_at:$now,updated_at:$now}')
		proposed=$(printf '%s' "$proposed" | jq -c --argjson item "$item" '. + [$item]')
	done < <(jq -c '.[]' "$input_file")
	local ledger
	ledger=$(jq -n --arg session "$SESSION_ID" --arg source "$source_boundary" --argjson items "$proposed" '{schema_version:1,session_boundary:$session,source_boundary:$source,items:$items}')
	atomic_write_json "$PROPOSALS_FILE" "$ledger"
	log_success "Observation proposals persisted to $PROPOSALS_FILE"
	return 0
}

finalize_proposals() {
	init_session_dir
	[[ -f "$PROPOSALS_FILE" ]] || return 0
	[[ -x "$MEMORY_HELPER" ]] || {
		log_error "Memory helper not found: $MEMORY_HELPER"
		return 1
	}
	local key item content type tags now updated status=0
	while IFS= read -r key; do
		item=$(jq -c --arg key "$key" '.items[] | select(.idempotency_key == $key)' "$PROPOSALS_FILE")
		content=$(printf '%s' "$item" | jq -r '.content')
		type=$(printf '%s' "$item" | jq -r '.type')
		tags=$(printf '%s' "$item" | jq -r '.tags')
		if "$MEMORY_HELPER" store --content "$content" --type "$type" --tags "$tags" --session-id "$SESSION_ID" --auto >/dev/null 2>&1; then
			now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
			updated=$(jq --arg key "$key" --arg now "$now" '(.items[] | select(.idempotency_key == $key)) |= (.state="finalized" | .updated_at=$now)' "$PROPOSALS_FILE")
			atomic_write_json "$PROPOSALS_FILE" "$updated"
		else
			status=1
		fi
	done < <(jq -r --arg pending "$DISTILL_PROPOSAL_PENDING" '.items[] | select(.state == $pending and .type == "USER_PREFERENCE" and .explicit == true and .risk == "low") | .idempotency_key' "$PROPOSALS_FILE")
	return "$status"
}

#######################################
# Full auto pipeline
#######################################
_distill_active_task_count() {
	local repository_root=""
	local todo_file=""
	local count=0
	repository_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
	for todo_file in "${repository_root}/TODO.md" "$(pwd)/TODO.md"; do
		[[ -f "$todo_file" ]] || continue
		count=$(grep -Ec '^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]+' "$todo_file" 2>/dev/null || true)
		break
	done
	printf '%s\n' "${count:-0}"
	return 0
}

_distill_worktree_count() {
	local count=0
	count=$(git worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || true)
	printf '%s\n' "${count:-0}"
	return 0
}

_distill_proposal_count() {
	local state="$1"
	local count=0
	if [[ -f "$PROPOSALS_FILE" ]]; then
		count=$(jq --arg state "$state" '[.items[]? | select(.state == $state)] | length' "$PROPOSALS_FILE" 2>/dev/null || true)
	fi
	printf '%s\n' "${count:-0}"
	return 0
}

_distill_print_auto_receipt() {
	local checkpoint_status="$1"
	local proposal_status="$2"
	local finalization_status="$3"
	local blocker="$4"
	local checkpoint_file="$SESSION_STATE_DIR/operational-state.md"
	local active_tasks="" worktrees="" pending="" finalized="" resumability="unavailable"
	active_tasks=$(_distill_active_task_count)
	worktrees=$(_distill_worktree_count)
	pending=$(_distill_proposal_count "$DISTILL_PROPOSAL_PENDING")
	finalized=$(_distill_proposal_count "finalized")
	if [[ -f "$checkpoint_file" || -f "$PROPOSALS_FILE" ]]; then
		resumability="ready"
	fi
	cat <<EOF
schema: aidevops.session-distill-receipt/v1
checkpoint: $checkpoint_status
operational_state: $checkpoint_file
active_tasks: $active_tasks
worktrees: $worktrees
proposal_ledger: $PROPOSALS_FILE
proposals_pending: $pending
proposals_finalized: $finalized
proposal_status: $proposal_status
finalization_status: $finalization_status
resumability: $resumability
blocker: $blocker
EOF
	return 0
}

auto_distill() {
	local checkpoint_status="saved"
	local proposal_status="saved"
	local finalization_status="complete"
	local blocker="$DISTILL_STATUS_NONE"
	# Continuity is independent: capture it even when learning extraction or storage fails.
	if ! emit_checkpoint quiet >/dev/null 2>&1; then
		checkpoint_status="failed"
		blocker="checkpoint"
	fi
	if ! analyze_session >/dev/null 2>&1; then
		proposal_status="$DISTILL_STATUS_NOT_RUN"
		finalization_status="$DISTILL_STATUS_NOT_RUN"
		[[ "$blocker" == "$DISTILL_STATUS_NONE" ]] && blocker="analysis" || blocker="${blocker},analysis"
	elif ! extract_learnings >/dev/null 2>&1; then
		proposal_status="$DISTILL_STATUS_NOT_RUN"
		finalization_status="$DISTILL_STATUS_NOT_RUN"
		[[ "$blocker" == "$DISTILL_STATUS_NONE" ]] && blocker="extraction" || blocker="${blocker},extraction"
	elif ! propose_learnings >/dev/null 2>&1; then
		proposal_status="failed"
		finalization_status="$DISTILL_STATUS_NOT_RUN"
		[[ "$blocker" == "$DISTILL_STATUS_NONE" ]] && blocker="proposal" || blocker="${blocker},proposal"
	elif ! finalize_proposals >/dev/null 2>&1; then
		finalization_status="incomplete"
		[[ "$blocker" == "$DISTILL_STATUS_NONE" ]] && blocker="finalization" || blocker="${blocker},finalization"
	fi
	_distill_print_auto_receipt "$checkpoint_status" "$proposal_status" "$finalization_status" "$blocker"
	return 0
}

#######################################
# Emit operational state checkpoint
# Captures what tasks are running, PRs pending, etc.
# Complements learnings (what we learned) with state (where we are)
#######################################
emit_checkpoint() {
	local presentation_mode="${1:-full}"
	case "$presentation_mode" in
	full | quiet) ;;
	*)
		log_error "Unknown checkpoint presentation mode: $presentation_mode"
		return 1
		;;
	esac
	init_session_dir

	log_info "Capturing operational state..."

	local checkpoint_helper="$SCRIPT_DIR/session-checkpoint-helper.sh"

	if [[ -x "$checkpoint_helper" ]]; then
		# Generate continuation prompt (captures git, supervisor, PR, TODO state)
		local continuation_output
		if ! continuation_output=$(bash "$checkpoint_helper" continuation 2>/dev/null); then
			log_error "Checkpoint helper failed"
			return 1
		fi

		# Save to session dir for inclusion in distill output
		local checkpoint_file="$SESSION_STATE_DIR/operational-state.md"
		printf '%s\n' "$continuation_output" >"$checkpoint_file"

		log_success "Operational state saved to $checkpoint_file"
		if [[ "$presentation_mode" == "full" ]]; then
			printf '%s\n' "$continuation_output"
		fi
	else
		log_warn "session-checkpoint-helper.sh not found at $checkpoint_helper"

		# Fallback: gather minimal state directly
		local branch
		branch=$(git branch --show-current 2>/dev/null || echo "unknown")
		local open_prs
		open_prs=$(gh pr list --state open --json number,title --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null || echo "none")

		cat <<FALLBACK_EOF
## Operational State (fallback)

**Branch**: $branch
**Open PRs**: $open_prs
**Uncommitted**: $(git status --short 2>/dev/null || echo "unknown")
FALLBACK_EOF
		return 1
	fi
	return 0
}

#######################################
# Generate distillation prompt for AI
# Returns a prompt the AI can use to reflect on the session
#######################################
generate_prompt() {
	init_session_dir

	# Reuse the same authoritative provenance boundary as automatic extraction.
	local analysis_file="$SESSION_STATE_DIR/session-analysis.json"
	[[ -f "$analysis_file" ]] || analyze_session >/dev/null
	local branch commits_today attribution_status
	branch=$(jq -r '.branch // "unavailable"' "$analysis_file")
	commits_today=$(jq -r '.recent_commits[]?' "$analysis_file")
	attribution_status=$(jq -r '.commit_attribution // "unavailable"' "$analysis_file")

	cat <<EOF
## Session Reflection Prompt

Review this session and identify learnings worth remembering:

**Branch**: $branch
**Commit attribution**: $attribution_status

**Today's commits**:
$commits_today

**Questions to consider**:
1. What problems were solved? (→ WORKING_SOLUTION)
2. What approaches failed? (→ FAILED_APPROACH)
3. What patterns were discovered? (→ CODEBASE_PATTERN)
4. What user preferences were expressed? (→ USER_PREFERENCE)
5. What tool configurations worked well? (→ TOOL_CONFIG)
6. What decisions were made and why? (→ DECISION)

For each observation, create JSON with type, content, tags, explicit, and risk:
\`\`\`bash
~/.aidevops/agents/scripts/session-distill-helper.sh propose observations.json
~/.aidevops/agents/scripts/session-distill-helper.sh finalize
\`\`\`

Only directly stated, low-risk user preferences may set explicit=true and
risk=low. Keep inferred and consequential observations pending for review.
EOF
	return 0
}

#######################################
# Show help
#######################################
show_help() {
	cat <<'EOF'
Session Distill Helper - Extract learnings from session for memory storage

Usage:
  session-distill-helper.sh analyze     Analyze current session context
  session-distill-helper.sh extract     Extract and format learnings
  session-distill-helper.sh propose [file] Persist privacy-scanned observation proposals
  session-distill-helper.sh finalize    Finalize only low-risk explicit preferences
  session-distill-helper.sh provenance Capture authoritative session git provenance
  session-distill-helper.sh checkpoint  Capture and display full operational state
  session-distill-helper.sh auto        Persist full state; print a compact receipt
  session-distill-helper.sh prompt      Generate reflection prompt for AI
  session-distill-helper.sh help        Show this help

The distillation process:
  1. analyze    - Gathers git history, TODO.md changes, session patterns
  2. extract    - Identifies valuable learnings from patterns
  3. propose    - Privacy-redacts and persists resumable observations
  4. finalize   - Stores only low-risk explicit preferences
  5. provenance - Captures session-bound commit, branch, worktree, and PR evidence
  6. checkpoint - Captures operational state independently

Learning types detected:
  - ERROR_FIX: Bug fixes and error resolutions
  - WORKING_SOLUTION: Successful implementations
  - CODEBASE_PATTERN: Refactoring and structural changes
  - CONTEXT: Documentation and context updates

Integration:
  - Called by /session-review at end of sessions
  - Works with memory-helper.sh (persistent storage)
  - Works with session-checkpoint-helper.sh (operational state)
  - Supports both automatic and AI-assisted distillation

Examples:
  # Full automatic distillation (learnings + operational state)
  session-distill-helper.sh auto

  # Just capture operational state
  session-distill-helper.sh checkpoint

  # Generate prompt for AI-assisted reflection
  session-distill-helper.sh prompt

  # Manual step-by-step
  session-distill-helper.sh analyze
  session-distill-helper.sh extract
  session-distill-helper.sh store
EOF
	return 0
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	analyze)
		analyze_session
		;;
	extract)
		extract_learnings
		;;
	store | propose)
		propose_learnings "${1:-}"
		;;
	finalize)
		finalize_proposals
		;;
	provenance)
		capture_git_provenance "$@"
		;;
	checkpoint)
		emit_checkpoint
		;;
	auto)
		auto_distill
		;;
	prompt)
		generate_prompt
		;;
	help | --help | -h)
		show_help
		;;
	*)
		log_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
