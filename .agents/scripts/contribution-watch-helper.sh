#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# contribution-watch-helper.sh — Monitor external issues/PRs for new activity (t1419)
#
# Auto-discovers and monitors external GitHub issues/PRs where the
# authenticated user has contributed (authored or commented). Uses
# GitHub Notifications API for low-cost polling, with managed-repo
# exclusion to suppress aidevops automation noise.
#
# Architecture principle: the automated system (pulse/launchd) NEVER
# processes untrusted comment bodies through an LLM. It only performs
# deterministic timestamp/authorship checks. Comment bodies are only
# shown in interactive sessions after prompt-guard-helper.sh scanning.
#
# Usage:
#   contribution-watch-helper.sh seed [--dry-run]          Discover all external contributions
#   contribution-watch-helper.sh scan [--backfill]         Check notifications for new external activity
#                                                         Optional: metadata-only safety-net sweep of tracked threads
#   contribution-watch-helper.sh scan [--auto-draft]       Also create draft replies for items needing attention
#                                                         Drafts stored in ~/.aidevops/.agent-workspace/draft-responses/
#                                                         Use draft-response-helper.sh to review and approve (t1555)
#   contribution-watch-helper.sh stop                      Stop a running scan (via PID file)
#   contribution-watch-helper.sh restart                   Stop existing scan and start a new one
#   contribution-watch-helper.sh status                    Show watched items and their state
#   contribution-watch-helper.sh install                   Install launchd plist
#   contribution-watch-helper.sh uninstall                 Remove launchd plist
#   contribution-watch-helper.sh help                      Show usage
#
# State file: ~/.aidevops/cache/contribution-watch.json
# Launchd label: sh.aidevops.contribution-watch

set -euo pipefail

# PATH normalisation for launchd/MCP environments
_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"
if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" && -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
	_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin"
fi
export PATH="${_aidevops_path_prefix}:${PATH}"
unset _aidevops_path_prefix

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours if shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Configuration
# =============================================================================

STATE_FILE="${HOME}/.aidevops/cache/contribution-watch.json"
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
LOGFILE="${HOME}/.aidevops/logs/contribution-watch.log"
PID_FILE="${HOME}/.aidevops/.pid/contribution-watch.pid"
PLIST_LABEL="sh.aidevops.contribution-watch"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"

# Adaptive polling intervals (seconds)
POLL_HOT=900       # 15 minutes — activity within last 24h
POLL_DEFAULT=3600  # 1 hour — normal
POLL_DORMANT=21600 # 6 hours — no activity for 7+ days

# Thresholds (seconds)
HOT_THRESHOLD=86400      # 24 hours
DORMANT_THRESHOLD=604800 # 7 days

# GitHub API page size
API_PAGE_SIZE=100

# Backfill safety-net cadence (hours). Default is daily.
BACKFILL_FRESHNESS_HOURS="${CONTRIB_BACKFILL_HOURS:-24}"

# Notification reasons that are likely to need a human response.
# Excludes low-signal reasons such as ci_activity and state_change.
SIGNAL_REASONS="author|comment|mention|review_requested|subscribed"

# =============================================================================
# Logging
# =============================================================================

_log() {
	local level="$1"
	shift
	local msg="$*"
	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	echo "[${timestamp}] [${level}] ${msg}" >>"$LOGFILE"
	return 0
}

_log_info() {
	_log "INFO" "$@"
	return 0
}

_log_warn() {
	_log "WARN" "$@"
	return 0
}

_log_error() {
	_log "ERROR" "$@"
	return 0
}

# =============================================================================
# Prerequisites
# =============================================================================

_check_prerequisites() {
	if ! command -v gh &>/dev/null; then
		echo -e "${RED}Error: gh CLI not found. Install from https://cli.github.com/${NC}" >&2
		return 1
	fi
	_check_jq_prerequisite || return 1
	if ! gh auth status &>/dev/null 2>&1; then
		echo -e "${RED}Error: gh not authenticated. Run: gh auth login${NC}" >&2
		return 1
	fi
	return 0
}

_check_jq_prerequisite() {
	if ! command -v jq &>/dev/null; then
		echo -e "${RED}Error: jq not found. Install with: brew install jq${NC}" >&2
		return 1
	fi
	return 0
}

_get_username() {
	local username
	username=$(gh api user --jq '.login' 2>/dev/null) || username=""
	if [[ -z "$username" ]]; then
		_log_error "Failed to resolve GitHub username via gh api user"
		echo -e "${RED}Error: Could not resolve GitHub username${NC}" >&2
		return 1
	fi
	echo "$username"
	return 0
}

# =============================================================================
# State file management
# =============================================================================

_ensure_state_file() {
	local state_dir
	state_dir=$(dirname "$STATE_FILE")
	mkdir -p "$state_dir" 2>/dev/null || true
	mkdir -p "$(dirname "$PID_FILE")" 2>/dev/null || true

	if [[ ! -f "$STATE_FILE" ]]; then
		echo '{"last_scan":"","items":{}}' >"$STATE_FILE"
		_log_info "Created new state file: $STATE_FILE"
	fi
	return 0
}

# Check whether a scan is already running via the PID file.
# Returns 0 if a scan is running, 1 if not (stale PID file is cleaned up).
_is_scan_running() {
	if [[ ! -f "$PID_FILE" ]]; then
		return 1
	fi

	local old_pid
	old_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
	# t2421: command-aware liveness — bare kill -0 lies on macOS PID reuse
	if [[ -n "$old_pid" ]] && [[ "$old_pid" =~ ^[0-9]+$ ]] && \
	   _is_process_alive_and_matches "$old_pid" "contribution-watch-helper"; then
		return 0
	fi

	# Stale PID file — remove it
	rm -f "$PID_FILE"
	return 1
}

_read_state() {
	_ensure_state_file
	cat "$STATE_FILE"
	return 0
}

_write_state() {
	local state="$1"
	_ensure_state_file
	echo "$state" | jq '.' >"$STATE_FILE" 2>/dev/null || {
		_log_error "Failed to write state file (invalid JSON)"
		return 1
	}
	return 0
}

# =============================================================================
# ISO 8601 date helpers
# =============================================================================

_now_iso() {
	date -u +%Y-%m-%dT%H:%M:%SZ
	return 0
}

# Parse an ISO 8601 UTC timestamp to epoch seconds on macOS.
# TZ=UTC is required: macOS date -j -f interprets the input as local time without it (GH#17699).
_parse_iso_macos_utc() {
	local iso_date="$1"
	local clean_date
	clean_date="${iso_date%Z}"
	clean_date="${clean_date%+00:00}"
	TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$clean_date" "+%s" 2>/dev/null || echo "0"
	return 0
}

_epoch_from_iso() {
	local iso_date="$1"
	if [[ "$(uname)" == "Darwin" ]]; then
		_parse_iso_macos_utc "$iso_date"
	else
		date -d "$iso_date" "+%s" 2>/dev/null || echo "0"
	fi
	return 0
}

_seconds_since() {
	local iso_date="$1"
	local then_epoch
	then_epoch=$(_epoch_from_iso "$iso_date")
	local now_epoch
	now_epoch=$(date +%s)
	echo $((now_epoch - then_epoch))
	return 0
}

_get_managed_repo_slugs() {
	if [[ ! -f "$REPOS_JSON" ]]; then
		return 0
	fi

	jq -r '.initialized_repos[] | select(.slug != null and .slug != "") | .slug' "$REPOS_JSON" 2>/dev/null || true
	return 0
}

_is_managed_repo() {
	local repo_slug="$1"
	local managed_slugs="$2"

	if [[ -z "$repo_slug" || -z "$managed_slugs" ]]; then
		return 1
	fi

	while IFS= read -r managed_slug; do
		if [[ -n "$managed_slug" && "$repo_slug" == "$managed_slug" ]]; then
			return 0
		fi
	done <<<"$managed_slugs"

	return 1
}

_is_signal_reason() {
	local reason="$1"
	if [[ -z "$reason" ]]; then
		return 1
	fi
	if [[ "$reason" =~ ^(${SIGNAL_REASONS})$ ]]; then
		return 0
	fi
	return 1
}

_extract_item_key() {
	local subject_url="$1"
	if [[ -z "$subject_url" ]]; then
		echo ""
		return 0
	fi

	# Expected formats:
	#   https://api.github.com/repos/owner/repo/issues/123
	#   https://api.github.com/repos/owner/repo/pulls/456
	local path
	path="${subject_url#https://api.github.com/repos/}"
	if [[ "$path" == "$subject_url" ]]; then
		echo ""
		return 0
	fi

	local owner repo kind number
	owner=$(echo "$path" | cut -d'/' -f1)
	repo=$(echo "$path" | cut -d'/' -f2)
	kind=$(echo "$path" | cut -d'/' -f3)
	number=$(echo "$path" | cut -d'/' -f4)

	if [[ -z "$owner" || -z "$repo" || -z "$number" ]]; then
		echo ""
		return 0
	fi

	if [[ "$kind" != "issues" && "$kind" != "pulls" ]]; then
		echo ""
		return 0
	fi

	echo "${owner}/${repo}#${number}"
	return 0
}

_notification_item_type() {
	local subject_type="$1"
	if [[ "$subject_type" == "PullRequest" ]]; then
		echo "pr"
		return 0
	fi
	echo "issue"
	return 0
}

# =============================================================================
# Seed helpers
# =============================================================================

# Fetch authored and commented contributions. Sets globals:
#   _SEED_ALL_ITEMS  — deduplicated JSON array of all items
#   _SEED_AUTHORED   — raw authored JSON (for role detection)
_seed_fetch_contributions() {
	local username="$1"

	echo -e "${CYAN}Searching for authored issues/PRs...${NC}"
	_SEED_AUTHORED=$(gh api "search/issues?q=author:${username}+is:open&per_page=${API_PAGE_SIZE}&sort=updated" \
		--jq '.items[] | {url: .html_url, repo: .repository_url, number: .number, title: .title, type: (if .pull_request then "pr" else "issue" end), updated: .updated_at, created: .created_at}' \
		2>/dev/null) || _SEED_AUTHORED=""

	echo -e "${CYAN}Searching for commented issues/PRs...${NC}"
	local commented_json
	commented_json=$(gh api "search/issues?q=commenter:${username}+is:open&per_page=${API_PAGE_SIZE}&sort=updated" \
		--jq '.items[] | {url: .html_url, repo: .repository_url, number: .number, title: .title, type: (if .pull_request then "pr" else "issue" end), updated: .updated_at, created: .created_at}' \
		2>/dev/null) || commented_json=""

	_SEED_ALL_ITEMS=$(printf '%s\n%s' "$_SEED_AUTHORED" "$commented_json" | jq -s 'unique_by(.url)' 2>/dev/null) || _SEED_ALL_ITEMS="[]"
	return 0
}

# Update state JSON for a single seed item. Prints updated state.
_seed_update_state() {
	local state="$1"
	local item_key="$2"
	local item_type="$3"
	local role="$4"
	local title="$5"
	local updated="$6"

	echo "$state" | jq \
		--arg key "$item_key" \
		--arg type "$item_type" \
		--arg role "$role" \
		--arg title "$title" \
		--arg updated "$updated" \
		'
		if .items[$key] == null then
			.items[$key] = {
				type: $type,
				role: $role,
				title: $title,
				last_our_comment: "",
				last_any_comment: $updated,
				last_notified: "",
				hot_until: ""
			}
		else
			.items[$key].title = $title |
			.items[$key].last_any_comment = (if ($updated > .items[$key].last_any_comment) then $updated else .items[$key].last_any_comment end)
		end
	'
	return 0
}

# Check whether a repo slug matches any of the pipe-delimited own_repos.
_seed_is_own_repo() {
	local repo_slug="$1"
	local own_repos="$2"

	if [[ -z "$own_repos" ]]; then
		return 1
	fi

	local own_slug
	while IFS='|' read -r own_slug _rest; do
		if [[ "$repo_slug" == "$own_slug" ]]; then
			return 0
		fi
	done <<<"$(echo "$own_repos" | tr '|' '\n')"

	return 1
}

# Process a single seed item. Prints the updated state JSON.
# Returns 0 if item was added, 1 if skipped.
_seed_process_single_item() {
	local index="$1"
	local own_repos="$2"
	local dry_run="$3"
	local state="$4"

	local item repo_url repo_slug
	item=$(echo "$_SEED_ALL_ITEMS" | jq ".[$index]")
	repo_url=$(echo "$item" | jq -r '.repo')
	repo_slug=$(echo "$repo_url" | sed 's|https://api.github.com/repos/||')

	# Skip our own repos (pulse-enabled)
	if _seed_is_own_repo "$repo_slug" "$own_repos"; then
		echo "$state"
		return 1
	fi

	local number item_type title updated item_key role
	number=$(echo "$item" | jq -r '.number')
	item_type=$(echo "$item" | jq -r '.type')
	title=$(echo "$item" | jq -r '.title')
	updated=$(echo "$item" | jq -r '.updated')
	item_key="${repo_slug}#${number}"

	# Determine role: author if item appears in authored results
	role="commenter"
	if echo "$_SEED_AUTHORED" | jq -e "select(.number == ${number})" &>/dev/null 2>&1; then
		role="author"
	fi

	if [[ "$dry_run" == "true" ]]; then
		echo "  ${item_key} (${item_type}, ${role}): ${title}" >&2
		echo "$state"
	else
		_seed_update_state "$state" "$item_key" "$item_type" "$role" "$title" "$updated"
	fi
	return 0
}

# Iterate all fetched items, filter external, and update state.
# Writes updated state JSON to the file path in $1 (temp file).
# Writes item count to the file path in $2 (temp file).
_seed_process_items() {
	local own_repos="$1"
	local dry_run="$2"
	local state="$3"
	local state_out="$4"
	local count_out="$5"

	local items_added=0

	local total_found
	total_found=$(echo "$_SEED_ALL_ITEMS" | jq 'length')
	echo -e "${CYAN}Found ${total_found} total items. Filtering external repos...${NC}"

	local item_count i=0
	item_count=$(echo "$_SEED_ALL_ITEMS" | jq 'length')

	while [[ "$i" -lt "$item_count" ]]; do
		local new_state
		if new_state=$(_seed_process_single_item "$i" "$own_repos" "$dry_run" "$state"); then
			items_added=$((items_added + 1))
		fi
		state="$new_state"
		i=$((i + 1))
	done

	echo "$state" >"$state_out"
	printf '%s' "$items_added" >"$count_out"
	return 0
}

# Save seed results and print summary.
_seed_finalize() {
	local dry_run="$1"
	local state="$2"
	local items_added="$3"

	if [[ "$dry_run" == "true" ]]; then
		echo ""
		echo -e "${GREEN}Dry run complete: ${items_added} external items found${NC}"
	else
		local now_iso
		now_iso=$(_now_iso)
		state=$(echo "$state" | jq --arg ts "$now_iso" '.last_scan = $ts')
		_write_state "$state"
		echo -e "${GREEN}Seed complete: ${items_added} external items tracked${NC}"
		_log_info "Seed complete: ${items_added} items added"
	fi
	return 0
}

# =============================================================================
# Seed: discover all external contributions
# =============================================================================

cmd_seed() {
	local dry_run=false
	local arg
	for arg in "$@"; do
		if [[ "$arg" == "--dry-run" ]]; then
			dry_run=true
		fi
	done

	_check_prerequisites || return 1

	local username
	username=$(_get_username) || return 1

	echo -e "${BLUE}Discovering external contributions for @${username}...${NC}"
	_log_info "Seed started for @${username} (dry_run=${dry_run})"

	# Get all registered repos to exclude, including dormant safety scope.
	local own_repos=""
	if [[ -f "$REPOS_JSON" ]]; then
		own_repos=$(jq -r '.initialized_repos[] | .slug // empty' "$REPOS_JSON" 2>/dev/null | tr '\n' '|')
	fi

	local state
	state=$(_read_state)

	# Fetch contributions into globals _SEED_ALL_ITEMS and _SEED_AUTHORED
	_SEED_ALL_ITEMS="" _SEED_AUTHORED=""
	_seed_fetch_contributions "$username"

	# Process items and update state via temp files (avoids subshell variable loss)
	local tmp_state tmp_count
	tmp_state=$(mktemp) || return 1
	tmp_count=$(mktemp) || {
		rm -f "$tmp_state"
		return 1
	}
	trap 'rm -f "$tmp_state" "$tmp_count"' RETURN

	_seed_process_items "$own_repos" "$dry_run" "$state" "$tmp_state" "$tmp_count"
	state=$(cat "$tmp_state")
	local items_added
	items_added=$(cat "$tmp_count")

	_seed_finalize "$dry_run" "$state" "$items_added"

	return 0
}

# =============================================================================
# Scan helpers
# =============================================================================

# Determine whether a backfill sweep is due. Prints "true" or "false".
_scan_check_backfill_due() {
	local state="$1"

	if ! [[ "$BACKFILL_FRESHNESS_HOURS" =~ ^[0-9]+$ ]] || [[ "$BACKFILL_FRESHNESS_HOURS" -eq 0 ]]; then
		BACKFILL_FRESHNESS_HOURS=24
	fi

	local last_backfill
	last_backfill=$(echo "$state" | jq -r '.last_backfill // ""')

	if [[ -z "$last_backfill" ]]; then
		echo "true"
		return 0
	fi

	local last_backfill_epoch now_epoch backfill_elapsed
	last_backfill_epoch=$(_epoch_from_iso "$last_backfill")
	now_epoch=$(date +%s)
	backfill_elapsed=$((now_epoch - last_backfill_epoch))

	if [[ "$backfill_elapsed" -ge $((BACKFILL_FRESHNESS_HOURS * 3600)) ]]; then
		echo "true"
	else
		echo "false"
	fi
	return 0
}

# Mark an item as needing attention. Updates _SCAN_STATE, _SCAN_ALERTED_KEYS,
# _SCAN_NEEDS_ATTENTION, _SCAN_ATTENTION_ITEMS, _SCAN_ITEMS_CHECKED.
# Returns 1 if the item was already alerted or not newer than last_notified.
_scan_alert_item() {
	local item_key="$1"
	local item_type="$2"
	local title="$3"
	local updated="$4"
	local reason="$5"

	local last_notified
	last_notified=$(echo "$_SCAN_STATE" | jq -r --arg key "$item_key" '.items[$key].last_notified // ""')
	[[ -n "$last_notified" ]] && [[ ! "$updated" > "$last_notified" ]] && return 1
	[[ "$_SCAN_ALERTED_KEYS" == *$'\n'"$item_key"$'\n'* ]] && return 1

	local hot_until
	hot_until=$(date -u -v+24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
	_SCAN_STATE=$(echo "$_SCAN_STATE" | jq \
		--arg key "$item_key" \
		--arg updated "$updated" \
		--arg hot "$hot_until" \
		'.items[$key].last_notified = $updated | .items[$key].hot_until = $hot')

	_SCAN_ALERTED_KEYS+="${item_key}"$'\n'
	_SCAN_NEEDS_ATTENTION=$((_SCAN_NEEDS_ATTENTION + 1))
	_SCAN_ATTENTION_ITEMS="${_SCAN_ATTENTION_ITEMS}  ${item_key} (${item_type}): ${title} — reason: ${reason}\n"
	_SCAN_ITEMS_CHECKED=$((_SCAN_ITEMS_CHECKED + 1))
	return 0
}

# Process the notifications stream. Updates _SCAN_STATE, _SCAN_NEEDS_ATTENTION,
# _SCAN_ATTENTION_ITEMS, _SCAN_ITEMS_CHECKED, _SCAN_ALERTED_KEYS in place.
_scan_process_notifications() {
	local notifications="$1"
	local managed_slugs="$2"
	local username="$3"

	while IFS= read -r row; do
		[[ -z "$row" ]] && continue
		_SCAN_NOTIFICATIONS_CHECKED=$((_SCAN_NOTIFICATIONS_CHECKED + 1))

		local repo_slug reason subject_url item_key item_type title updated
		repo_slug=$(echo "$row" | jq -r '.repository.full_name // ""')
		[[ -z "$repo_slug" ]] && continue
		_is_managed_repo "$repo_slug" "$managed_slugs" && continue

		reason=$(echo "$row" | jq -r '.reason // ""')
		_is_signal_reason "$reason" || continue

		subject_url=$(echo "$row" | jq -r '.subject.url // ""')
		item_key=$(_extract_item_key "$subject_url")
		[[ -z "$item_key" ]] && continue

		item_type=$(_notification_item_type "$(echo "$row" | jq -r '.subject.type // "Issue"')")
		title=$(echo "$row" | jq -r '.subject.title // "unknown"')
		updated=$(echo "$row" | jq -r '.updated_at // ""')
		[[ -z "$updated" ]] && continue

		# For comment-driven notifications, resolve latest comment metadata so we can
		# detect self activity by aidevops signature footer, not only by username.
		if [[ "$reason" == "comment" || "$reason" == "mention" ]]; then
			local number latest_meta latest_author latest_time latest_is_aidevops
			number="${item_key##*#}"
			latest_author=""
			latest_time=""
			latest_is_aidevops="false"

			if [[ "$number" =~ ^[0-9]+$ ]]; then
				latest_meta=$(_scan_backfill_fetch_latest_comment "$repo_slug" "$number" "$item_key")
				if [[ -n "$latest_meta" && "$latest_meta" != "null" ]]; then
					latest_author=$(echo "$latest_meta" | jq -r '.author // ""')
					latest_time=$(echo "$latest_meta" | jq -r '.created // ""')
					latest_is_aidevops=$(echo "$latest_meta" | jq -r '.is_aidevops // false')
				fi
			fi

			if [[ -n "$latest_time" && "$latest_time" > "$updated" ]]; then
				updated="$latest_time"
			fi

			if [[ "$latest_author" == "$username" || "$latest_is_aidevops" == "true" ]]; then
				_SCAN_STATE=$(echo "$_SCAN_STATE" | jq \
					--arg key "$item_key" \
					--arg type "$item_type" \
					--arg title "$title" \
					--arg updated "$updated" \
					'.items[$key] = ((.items[$key] // {type: $type, role: "participant", title: $title, last_our_comment: "", last_any_comment: "", last_notified: "", hot_until: ""})
						| .type = $type
						| .title = $title
						| .last_any_comment = (if .last_any_comment == "" or $updated > .last_any_comment then $updated else .last_any_comment end)
						| .last_our_comment = (if .last_our_comment == "" or $updated > .last_our_comment then $updated else .last_our_comment end)
					)')
				continue
			fi
		fi

		_SCAN_STATE=$(echo "$_SCAN_STATE" | jq \
			--arg key "$item_key" \
			--arg type "$item_type" \
			--arg title "$title" \
			--arg updated "$updated" \
			'.items[$key] = ((.items[$key] // {type: $type, role: "participant", title: $title, last_our_comment: "", last_any_comment: "", last_notified: "", hot_until: ""})
				| .type = $type
				| .title = $title
				| .last_any_comment = (if .last_any_comment == "" or $updated > .last_any_comment then $updated else .last_any_comment end)
			)')

		_scan_alert_item "$item_key" "$item_type" "$title" "$updated" "$reason" || true
	done < <(echo "$notifications" | jq -c '.[]?')
	return 0
}

# Fetch latest comment metadata for a tracked item during backfill.
# Prints JSON: {author, created} or empty string on failure.
_scan_backfill_fetch_latest_comment() {
	local repo_slug="$1"
	local number="$2"
	local key="$3"

	local issue_comments="[]"
	if ! issue_comments=$(gh api --paginate "repos/${repo_slug}/issues/${number}/comments" \
		--jq '[.[] | {author: .user.login, created: .created_at, body: (.body // "")}]' 2>/dev/null); then
		_log_warn "Backfill issue comments API failed for ${repo_slug}#${number}"
		issue_comments="[]"
	fi

	local pr_review_comments="[]"
	if ! pr_review_comments=$(gh api --paginate "repos/${repo_slug}/pulls/${number}/comments" \
		--jq '[.[] | {author: .user.login, created: .created_at, body: (.body // "")}]' 2>/dev/null); then
		local tracked_type
		tracked_type=$(echo "$_SCAN_STATE" | jq -r --arg key "$key" '.items[$key].type // "issue"')
		if [[ "$tracked_type" == "pr" ]]; then
			_log_warn "Backfill PR review comments API failed for ${repo_slug}#${number}"
		fi
		pr_review_comments="[]"
	fi

	jq -s 'add | sort_by(.created) | reverse | .[0] | {
		author: (.author // ""),
		created: (.created // ""),
		is_aidevops: ((.body // "") | test("aidevops\\.sh"))
	}' \
		<(echo "$issue_comments") <(echo "$pr_review_comments") 2>/dev/null || echo ""
	return 0
}

# Process a single backfill item: fetch comments, update state, alert if needed.
# Updates _SCAN_STATE, _SCAN_BACKFILL_CHECKED and alert globals.
_scan_backfill_process_item() {
	local key="$1"
	local managed_slugs="$2"
	local username="$3"

	_SCAN_BACKFILL_CHECKED=$((_SCAN_BACKFILL_CHECKED + 1))

	local repo_slug number
	repo_slug="${key%#*}"
	number="${key##*#}"

	_is_managed_repo "$repo_slug" "$managed_slugs" && return 0

	local comments_meta
	comments_meta=$(_scan_backfill_fetch_latest_comment "$repo_slug" "$number" "$key")
	[[ -z "$comments_meta" || "$comments_meta" == "null" ]] && return 0

	local latest_comment_author latest_comment_time latest_comment_is_aidevops
	latest_comment_author=$(echo "$comments_meta" | jq -r '.author // ""')
	latest_comment_time=$(echo "$comments_meta" | jq -r '.created // ""')
	latest_comment_is_aidevops=$(echo "$comments_meta" | jq -r '.is_aidevops // false')
	[[ -z "$latest_comment_time" ]] && return 0

	_SCAN_STATE=$(echo "$_SCAN_STATE" | jq \
		--arg key "$key" \
		--arg time "$latest_comment_time" \
		'.items[$key].last_any_comment = (if .items[$key].last_any_comment == "" or $time > .items[$key].last_any_comment then $time else .items[$key].last_any_comment end)')

	if [[ "$latest_comment_author" == "$username" || "$latest_comment_is_aidevops" == "true" ]]; then
		_SCAN_STATE=$(echo "$_SCAN_STATE" | jq --arg key "$key" --arg time "$latest_comment_time" '.items[$key].last_our_comment = $time')
		return 0
	fi

	local title item_type
	title=$(echo "$_SCAN_STATE" | jq -r --arg key "$key" '.items[$key].title // "unknown"')
	item_type=$(echo "$_SCAN_STATE" | jq -r --arg key "$key" '.items[$key].type // "issue"')

	_scan_alert_item "$key" "$item_type" "$title" "$latest_comment_time" "backfill" || true
	return 0
}

# Run backfill sweep over all tracked items. Updates _SCAN_STATE,
# _SCAN_NEEDS_ATTENTION, _SCAN_ATTENTION_ITEMS, _SCAN_ITEMS_CHECKED,
# _SCAN_ALERTED_KEYS, _SCAN_BACKFILL_CHECKED in place.
_scan_run_backfill() {
	local managed_slugs="$1"
	local username="$2"

	local items_keys
	items_keys=$(echo "$_SCAN_STATE" | jq -r '.items | keys[]' 2>/dev/null) || items_keys=""

	while IFS= read -r key; do
		[[ -z "$key" ]] && continue
		_scan_backfill_process_item "$key" "$managed_slugs" "$username"
	done <<<"$items_keys"
	return 0
}

# Handle auto-draft creation for items needing attention (t1555).
# AGENT COMPOSE INSTRUCTION (t5520): After composing a draft reply, assess
# whether a reply is actually needed. If the recommendation is "no reply
# needed", "no action required", or "decline", call:
#   draft-response-helper.sh reject <draft_id> "No reply needed"
# instead of leaving the notification issue open. This avoids requiring
# manual closure of no-reply drafts. The deterministic safety net in
# check-approvals will also auto-decline after 24h if the draft body
# contains clear no-reply indicators and no user comment exists.
_scan_handle_auto_draft() {
	local state="$1"
	local draft_helper="$2"
	local needs_attention="$3"

	local draft_enabled=true
	if type is_feature_enabled &>/dev/null && ! is_feature_enabled draft_responses 2>/dev/null; then
		draft_enabled=false
	fi

	if [[ "$draft_enabled" != "true" || "$needs_attention" -le 0 || ! -x "$draft_helper" ]]; then
		return 0
	fi

	local draft_keys
	draft_keys=$(echo "$state" | jq -r '
		.items | to_entries[] |
		select(.value.last_any_comment > (.value.last_our_comment // "")) |
		.key
	' 2>/dev/null) || draft_keys=""

	local draft_created=0 dk
	while IFS= read -r dk; do
		[[ -z "$dk" ]] && continue
		if bash "$draft_helper" draft "$dk" >/dev/null 2>&1; then
			draft_created=$((draft_created + 1))
		fi
	done <<<"$draft_keys"

	if [[ "$draft_created" -gt 0 ]]; then
		echo "Created ${draft_created} draft reply file(s). Review with: draft-response-helper.sh list --pending"
		_log_info "Auto-draft: created ${draft_created} draft(s)"
	fi
	return 0
}

# Handle check-approvals scan for pending draft responses (t1556).
_scan_handle_approvals() {
	local draft_helper="$1"

	local draft_enabled=true
	if type is_feature_enabled &>/dev/null && ! is_feature_enabled draft_responses 2>/dev/null; then
		draft_enabled=false
	fi

	if [[ "$draft_enabled" != "true" || ! -x "$draft_helper" ]]; then
		return 0
	fi

	_log_info "Running check-approvals scan"
	local approval_output=""
	if ! approval_output=$(bash "$draft_helper" check-approvals 2>&1); then
		_log_warn "Approval scan failed (exit $?): ${approval_output}"
		echo "Approval scan failed; see ${LOGFILE}."
	else
		echo "$approval_output"
	fi
	return 0
}

# Print scan summary and trigger macOS notification if needed.
_scan_print_results() {
	local needs_attention="$1"
	local attention_items="$2"
	local notifications_checked="$3"
	local items_checked="$4"
	local run_backfill="$5"
	local auto_backfill="$6"
	local backfill_checked="$7"

	if [[ "$needs_attention" -gt 0 ]]; then
		echo -e "${YELLOW}${needs_attention} external contribution(s) need your reply:${NC}"
		echo -e "$attention_items"
		# macOS notification disabled — Notification Center alert sounds
		# cannot be suppressed per-notification; they cause system beeps.
		# Re-enable: uncomment the osascript line below.
		# if [[ ! -t 0 ]] && command -v osascript &>/dev/null; then
		# 	osascript -e "display notification \"${needs_attention} contribution(s) need reply\" with title \"aidevops\"" 2>/dev/null || true
		# fi
	else
		echo -e "${GREEN}All caught up — no external contributions need attention${NC}"
	fi

	echo "Checked ${notifications_checked} notifications (${items_checked} actionable external threads)."
	if [[ "$run_backfill" == "true" ]]; then
		if [[ "$auto_backfill" == "true" ]]; then
			echo "Backfill sweep checked ${backfill_checked} tracked threads (auto cadence: ${BACKFILL_FRESHNESS_HOURS}h)."
		else
			echo "Backfill sweep checked ${backfill_checked} tracked threads."
		fi
	fi
	return 0
}

# Initialise shared scan globals from state file.
_scan_init_globals() {
	_SCAN_STATE=$(_read_state)
	_SCAN_NEEDS_ATTENTION=0
	_SCAN_ITEMS_CHECKED=0
	_SCAN_BACKFILL_CHECKED=0
	_SCAN_ATTENTION_ITEMS=""
	_SCAN_NOTIFICATIONS_CHECKED=0
	_SCAN_ALERTED_KEYS=$'\n'
	return 0
}

# Fetch and process the notifications stream.
_scan_fetch_and_process() {
	local last_scan="$1"
	local managed_slugs="$2"
	local username="$3"

	local since_arg=""
	[[ -n "$last_scan" ]] && since_arg="&since=${last_scan}"

	local notifications
	notifications=$(gh api --paginate "notifications?participating=true&all=true&per_page=${API_PAGE_SIZE}${since_arg}" 2>/dev/null) || notifications=""

	_scan_process_notifications "$notifications" "$managed_slugs" "$username"
	return 0
}

# Save scan state with updated timestamps.
_scan_save_state() {
	local run_backfill="$1"

	local now_iso
	now_iso=$(_now_iso)
	_SCAN_STATE=$(echo "$_SCAN_STATE" | jq --arg ts "$now_iso" '.last_scan = $ts')
	if [[ "$run_backfill" == "true" ]]; then
		_SCAN_STATE=$(echo "$_SCAN_STATE" | jq --arg ts "$now_iso" '.last_backfill = $ts')
	fi
	_write_state "$_SCAN_STATE"
	return 0
}

# Run post-scan actions: auto-draft, approvals, results, logging.
_scan_post_actions() {
	local auto_draft="$1"
	local run_backfill="$2"
	local auto_backfill="$3"

	local draft_helper="${SCRIPT_DIR}/draft-response-helper.sh"
	if [[ "$auto_draft" == "true" ]]; then
		_scan_handle_auto_draft "$_SCAN_STATE" "$draft_helper" "$_SCAN_NEEDS_ATTENTION"
	fi
	_scan_handle_approvals "$draft_helper"

	_scan_print_results "$_SCAN_NEEDS_ATTENTION" "$_SCAN_ATTENTION_ITEMS" \
		"$_SCAN_NOTIFICATIONS_CHECKED" "$_SCAN_ITEMS_CHECKED" \
		"$run_backfill" "$auto_backfill" "$_SCAN_BACKFILL_CHECKED"

	_log_info "Scan complete: notifications=${_SCAN_NOTIFICATIONS_CHECKED}, actionable=${_SCAN_ITEMS_CHECKED}, backfill_checked=${_SCAN_BACKFILL_CHECKED}, needs_attention=${_SCAN_NEEDS_ATTENTION}, run_backfill=${run_backfill}, auto_backfill=${auto_backfill}"

	echo "CONTRIBUTION_WATCH_COUNT=${_SCAN_NEEDS_ATTENTION}"
	return 0
}

# Parse scan CLI arguments. Sets _SCAN_ARG_BACKFILL, _SCAN_ARG_AUTO_DRAFT.
_scan_parse_args() {
	_SCAN_ARG_BACKFILL=false
	_SCAN_ARG_AUTO_BACKFILL=false
	_SCAN_ARG_AUTO_DRAFT=false
	local scan_arg
	for scan_arg in "$@"; do
		case "$scan_arg" in
		--backfill) _SCAN_ARG_BACKFILL=true ;;
		--auto-draft) _SCAN_ARG_AUTO_DRAFT=true ;;
		esac
	done
	return 0
}

# Auto-enable backfill when cadence threshold is reached.
# Updates _SCAN_ARG_BACKFILL and _SCAN_ARG_AUTO_BACKFILL in place.
_scan_maybe_auto_backfill() {
	if [[ "$_SCAN_ARG_BACKFILL" == "true" ]]; then
		return 0
	fi
	local backfill_due
	backfill_due=$(_scan_check_backfill_due "$_SCAN_STATE")
	if [[ "$backfill_due" == "true" ]]; then
		_SCAN_ARG_BACKFILL=true
		_SCAN_ARG_AUTO_BACKFILL=true
		_log_info "Auto-enabling backfill safety-net (cadence: ${BACKFILL_FRESHNESS_HOURS}h)"
	fi
	return 0
}

# =============================================================================
# Scan: check notifications for new external activity
# =============================================================================

cmd_scan() {
	_scan_parse_args "$@"

	_ensure_state_file

	# Guard: prevent multiple concurrent scan instances (GH#17415).
	# Check before prerequisites so the "already running" message is always shown.
	if _is_scan_running; then
		local running_pid
		running_pid=$(cat "$PID_FILE" 2>/dev/null || echo "unknown")
		echo -e "${YELLOW}[contribution-watch] Scan already running (PID ${running_pid}). Use 'stop' or 'restart' to control it.${NC}" >&2
		_log_warn "Scan skipped — already running (PID ${running_pid})"
		return 1
	fi

	_check_prerequisites || return 1

	_scan_init_globals

	local last_scan
	last_scan=$(echo "$_SCAN_STATE" | jq -r '.last_scan // ""')

	if [[ -z "$last_scan" ]]; then
		echo -e "${YELLOW}[contribution-watch] skipped — no previous scan found; run aidevops contribution-watch seed to enable${NC}"
		_log_info "Scan skipped — no prior seed"
		return 0
	fi

	local username
	username=$(_get_username) || return 1

	# Write our PID before starting work
	echo $$ >"$PID_FILE"

	# Remove PID file on exit (normal, Ctrl+C, or SIGTERM)
	trap 'rm -f "$PID_FILE"; trap - EXIT INT TERM' EXIT INT TERM

	_scan_maybe_auto_backfill
	_log_info "Scan started (last_scan: ${last_scan})"

	local managed_slugs
	managed_slugs=$(_get_managed_repo_slugs)

	_scan_fetch_and_process "$last_scan" "$managed_slugs" "$username"

	if [[ "$_SCAN_ARG_BACKFILL" == "true" ]]; then
		_scan_run_backfill "$managed_slugs" "$username"
	fi

	_scan_save_state "$_SCAN_ARG_BACKFILL"
	_scan_post_actions "$_SCAN_ARG_AUTO_DRAFT" "$_SCAN_ARG_BACKFILL" "$_SCAN_ARG_AUTO_BACKFILL"

	return 0
}

# =============================================================================
# Stop: stop a running scan via PID file
# =============================================================================

cmd_stop() {
	mkdir -p "$(dirname "$PID_FILE")" 2>/dev/null || true

	if [[ ! -f "$PID_FILE" ]]; then
		echo "[contribution-watch] No PID file found. Is a scan running?" >&2
		return 1
	fi

	local pid
	pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
	if [[ -z "$pid" ]] || ! [[ "$pid" =~ ^[0-9]+$ ]]; then
		echo "[contribution-watch] PID file is invalid. Removing stale file." >&2
		rm -f "$PID_FILE"
		return 1
	fi

	if ! kill -0 "$pid" 2>/dev/null; then
		echo "[contribution-watch] No running scan found (PID ${pid} is gone). Removing stale PID file."
		rm -f "$PID_FILE"
		return 0
	fi

	echo "[contribution-watch] Stopping scan (PID ${pid})..."
	kill -TERM "$pid" 2>/dev/null || true

	# Wait up to 5 seconds for the process to exit
	local waited=0
	while kill -0 "$pid" 2>/dev/null && [[ "$waited" -lt 5 ]]; do
		sleep 1
		waited=$((waited + 1))
	done

	if kill -0 "$pid" 2>/dev/null; then
		echo "[contribution-watch] Scan did not stop after SIGTERM, sending SIGKILL..."
		kill -KILL "$pid" 2>/dev/null || true
	fi

	rm -f "$PID_FILE"
	echo "[contribution-watch] Scan stopped."
	return 0
}

# =============================================================================
# Restart: stop any running scan and start a new one
# =============================================================================

cmd_restart() {
	local stop_rc=0
	cmd_stop 2>/dev/null || stop_rc=$?
	# stop_rc=1 is acceptable (no scan was running)
	cmd_scan "$@"
	return $?
}

# Classify a single status item into activity tiers and check if it needs reply.
# Updates globals: _STATUS_HOT, _STATUS_ACTIVE, _STATUS_DORMANT,
# _STATUS_NEEDS_REPLY, _STATUS_FOUND_NEEDING.
_status_classify_item() {
	local state="$1"
	local key="$2"

	local item title item_type last_any last_our role
	item=$(echo "$state" | jq --arg k "$key" '.items[$k]')
	title=$(echo "$item" | jq -r '.title // "unknown"')
	item_type=$(echo "$item" | jq -r '.type // "issue"')
	last_any=$(echo "$item" | jq -r '.last_any_comment // ""')
	last_our=$(echo "$item" | jq -r '.last_our_comment // ""')
	role=$(echo "$item" | jq -r '.role // "commenter"')

	# Determine activity tier
	if [[ -n "$last_any" ]]; then
		local age_seconds
		age_seconds=$(_seconds_since "$last_any")
		if [[ "$age_seconds" -lt "$HOT_THRESHOLD" ]]; then
			_STATUS_HOT=$((_STATUS_HOT + 1))
		elif [[ "$age_seconds" -gt "$DORMANT_THRESHOLD" ]]; then
			_STATUS_DORMANT=$((_STATUS_DORMANT + 1))
		else
			_STATUS_ACTIVE=$((_STATUS_ACTIVE + 1))
		fi
	fi

	# Check if needs reply (someone else has last word)
	if [[ -n "$last_any" && ("$last_our" < "$last_any" || -z "$last_our") ]]; then
		_STATUS_NEEDS_REPLY=$((_STATUS_NEEDS_REPLY + 1))
		_STATUS_FOUND_NEEDING=true
		echo "  ${key} (${item_type}, ${role}): ${title}"
		echo "    Last activity: ${last_any}"
	fi
	return 0
}

# Iterate all tracked items and classify them. Prints needs-reply items.
# Sets globals: _STATUS_HOT, _STATUS_ACTIVE, _STATUS_DORMANT,
# _STATUS_NEEDS_REPLY, _STATUS_FOUND_NEEDING.
_status_collect_items() {
	local state="$1"

	_STATUS_HOT=0
	_STATUS_ACTIVE=0
	_STATUS_DORMANT=0
	_STATUS_NEEDS_REPLY=0
	_STATUS_FOUND_NEEDING=false

	local keys
	keys=$(echo "$state" | jq -r '.items | keys[]' 2>/dev/null) || keys=""

	while IFS= read -r key; do
		[[ -z "$key" ]] && continue
		_status_classify_item "$state" "$key"
	done <<<"$keys"
	return 0
}

# Print activity tier summary and polling schedule.
_status_print_summary() {
	local hot_count="$1"
	local active_count="$2"
	local dormant_count="$3"
	local needs_reply_count="$4"
	local found_needing="$5"

	if [[ "$found_needing" == "false" ]]; then
		echo "  None — all caught up!"
	fi

	echo ""
	echo -e "${CYAN}Activity tiers:${NC}"
	echo "  Hot (<24h):     ${hot_count}"
	echo "  Active:         ${active_count}"
	echo "  Dormant (>7d):  ${dormant_count}"
	echo "  Need reply:     ${needs_reply_count}"

	echo ""
	echo -e "${CYAN}Polling schedule:${NC}"
	if [[ "$hot_count" -gt 0 ]]; then
		echo "  Current: every 15 minutes (hot items detected)"
	elif [[ "$active_count" -gt 0 ]]; then
		echo "  Current: every 1 hour (active items)"
	else
		echo "  Current: every 6 hours (all dormant)"
	fi
	return 0
}

# =============================================================================
# Status: show watched items
# =============================================================================

cmd_status() {
	_ensure_state_file

	local state
	state=$(_read_state)

	local last_scan
	last_scan=$(echo "$state" | jq -r '.last_scan // "never"')
	local item_count
	item_count=$(echo "$state" | jq '.items | length')

	echo -e "${BLUE}Contribution Watch Status${NC}"
	echo "========================="
	echo "Last scan: ${last_scan}"
	echo "Tracked items: ${item_count}"
	echo ""

	if [[ "$item_count" -eq 0 ]]; then
		echo "No items tracked. Run 'seed' to discover contributions."
		return 0
	fi

	echo -e "${CYAN}Items needing reply:${NC}"
	_status_collect_items "$state"
	_status_print_summary "$_STATUS_HOT" "$_STATUS_ACTIVE" "$_STATUS_DORMANT" \
		"$_STATUS_NEEDS_REPLY" "$_STATUS_FOUND_NEEDING"

	return 0
}

# Determine polling interval based on current state. Prints interval in seconds.
_install_get_interval() {
	local interval="$POLL_DEFAULT"
	if [[ -f "$STATE_FILE" ]]; then
		local state
		state=$(_read_state)
		local hot_count
		hot_count=$(echo "$state" | jq '[.items[] | select(.hot_until != "" and .hot_until != null)] | length' 2>/dev/null) || hot_count=0
		if [[ "$hot_count" -gt 0 ]]; then
			interval="$POLL_HOT"
		fi
	fi
	echo "$interval"
	return 0
}

# Write the launchd plist file for the scan schedule.
_install_write_plist() {
	local script_path="$1"
	local interval="$2"

	cat >"$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${PLIST_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${script_path}</string>
		<string>scan</string>
	</array>
	<key>StartInterval</key>
	<integer>${interval}</integer>
	<key>StandardOutPath</key>
	<string>${LOGFILE}</string>
	<key>StandardErrorPath</key>
	<string>${LOGFILE}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>${HOME}</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
PLIST
	return 0
}

# =============================================================================
# Install: create launchd plist
# =============================================================================

cmd_install() {
	local script_path
	script_path=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")

	local interval
	interval=$(_install_get_interval)

	mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
	_install_write_plist "$script_path" "$interval"

	launchctl unload "$PLIST_PATH" 2>/dev/null || true
	launchctl load "$PLIST_PATH" 2>/dev/null || true

	echo -e "${GREEN}Installed launchd plist: ${PLIST_LABEL}${NC}"
	echo "  Plist: ${PLIST_PATH}"
	echo "  Interval: every $((interval / 60)) minutes"
	echo "  Log: ${LOGFILE}"
	_log_info "Installed launchd plist (interval: ${interval}s)"

	return 0
}

# =============================================================================
# Uninstall: remove launchd plist
# =============================================================================

cmd_uninstall() {
	if [[ -f "$PLIST_PATH" ]]; then
		launchctl unload "$PLIST_PATH" 2>/dev/null || true
		rm -f "$PLIST_PATH"
		echo -e "${GREEN}Uninstalled launchd plist: ${PLIST_LABEL}${NC}"
		_log_info "Uninstalled launchd plist"
	else
		echo "No plist found at ${PLIST_PATH}"
	fi

	# Stop any running scan and clean up PID file
	if [[ -f "$PID_FILE" ]]; then
		cmd_stop 2>/dev/null || true
		rm -f "$PID_FILE"
	fi

	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	echo "contribution-watch-helper.sh — Monitor external issues/PRs for new activity"
	echo ""
	echo "Usage:"
	echo "  contribution-watch-helper.sh seed [--dry-run]              Discover all external contributions"
	echo "  contribution-watch-helper.sh scan [--backfill]             Check notifications for new external activity"
	echo "                                                             --backfill adds a metadata-only safety-net sweep"
	echo "  contribution-watch-helper.sh scan [--auto-draft]           Also create draft replies for items needing attention"
	echo "                                                             Drafts stored in ~/.aidevops/.agent-workspace/draft-responses/"
	echo "                                                             Use draft-response-helper.sh to review and approve"
	echo "  contribution-watch-helper.sh stop                          Stop a running scan (via PID file)"
	echo "  contribution-watch-helper.sh restart                       Stop existing scan and start a new one"
	echo "  contribution-watch-helper.sh status                        Show watched items and their state"
	echo "  contribution-watch-helper.sh install                       Install launchd plist"
	echo "  contribution-watch-helper.sh uninstall                     Remove launchd plist"
	echo "  contribution-watch-helper.sh help                          Show this help"
	echo ""
	echo "State file: ${STATE_FILE}"
	echo "Log file:   ${LOGFILE}"
	echo ""
	echo "Architecture: Automated scans are deterministic (notification metadata only)."
	echo "Managed repos (pulse=true in repos.json) are excluded to suppress internal automation noise."
	echo "Default scan auto-runs a low-frequency backfill sweep every ${BACKFILL_FRESHNESS_HOURS}h."
	echo "Comment bodies are NEVER processed by LLM in automated context."
	echo "Use prompt-guard-helper.sh scan before showing comment bodies interactively."
	echo ""
	echo "Draft responses (t1555):"
	echo "  scan --auto-draft creates draft reply files for items needing attention."
	echo "  Drafts are NEVER posted automatically — use draft-response-helper.sh approve <id>."
	echo ""
	echo "Approval scanning (t1556):"
	echo "  Every scan cycle checks notification issues for user comments."
	echo "  When found, an LLM interprets the user's intent (approve/decline/redraft/custom)."
	echo "  Bot comments are filtered out. Role-based compose caps enforced."
	echo "  Run manually: draft-response-helper.sh check-approvals"
	return 0
}

# =============================================================================
# Main dispatch
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift 2>/dev/null || true

	# Ensure log directory exists
	mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

	case "$cmd" in
	seed) cmd_seed "$@" ;;
	scan) cmd_scan "$@" ;;
	stop) cmd_stop "$@" ;;
	restart) cmd_restart "$@" ;;
	status) cmd_status "$@" ;;
	install) cmd_install "$@" ;;
	uninstall) cmd_uninstall "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		echo -e "${RED}Unknown command: ${cmd}${NC}" >&2
		echo "Run 'contribution-watch-helper.sh help' for usage." >&2
		return 1
		;;
	esac
}

main "$@"
