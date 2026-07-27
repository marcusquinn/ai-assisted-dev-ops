#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Upstream Watch Check -- Probe, compare, and report upstream changes
# =============================================================================
# Sub-library for upstream-watch-helper.sh. Contains all GitHub API probing,
# update checking, diff display, and the cmd_check command.
#
# Usage: source "${SCRIPT_DIR}/upstream-watch-helper-check.sh"
#
# Dependencies:
#   - shared-constants.sh (colour vars, gh wrappers)
#   - upstream-watch-helper-state.sh (_log_*, _read_state, _write_state, etc.)
#   - upstream-watch-helper-issues.sh (_file_upstream_update_issue)
#   - Expects CONFIG_FILE, STATE_FILE globals set by orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_UPSTREAM_WATCH_CHECK_LIB_LOADED:-}" ]] && return 0
_UPSTREAM_WATCH_CHECK_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

readonly UPSTREAM_WATCH_MODE_RELEASES="releases"
readonly UPSTREAM_WATCH_MODE_RELEASES_AND_COMMITS="releases-and-commits"

# =============================================================================
# GitHub API probes
# =============================================================================

#######################################
# Validate a GitHub upstream watch mode.
# Arguments:
#   $1 - Watch mode
# Returns: 0 when supported, 1 otherwise
#######################################
_upstream_watch_mode_valid() {
	local watch_mode="$1"
	if [[ "$watch_mode" == "$UPSTREAM_WATCH_MODE_RELEASES" || "$watch_mode" == "$UPSTREAM_WATCH_MODE_RELEASES_AND_COMMITS" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Seed missing runtime state from a committed review baseline.
# Existing runtime state always wins so acknowledgements remain local.
# Arguments:
#   $1 - Repository slug
#   $2 - Config entry JSON
#######################################
_initialize_github_repo_state() {
	local slug="$1"
	local entry_json="$2"

	if printf '%s' "$_check_state" | jq -e --arg slug "$slug" '.repos[$slug] != null' >/dev/null 2>&1; then
		return 0
	fi

	local baseline_release baseline_commit
	baseline_release=$(printf '%s' "$entry_json" | jq -r '.baseline_release // ""')
	baseline_commit=$(printf '%s' "$entry_json" | jq -r '.baseline_commit // ""')
	_check_state=$(printf '%s' "$_check_state" | jq --arg slug "$slug" \
		--arg release "$baseline_release" --arg commit "${baseline_commit:0:7}" \
		'.repos[$slug] = {
			last_release_seen: $release,
			last_commit_seen: $commit,
			last_checked: "",
			updates_pending: 0
		}') || return 1
	return 0
}

#######################################
# Probe GitHub API for the latest release of a repository.
# Echoes release JSON on success; empty string if no releases (404).
# Arguments:
#   $1 - Repository slug (owner/repo)
# Outputs: release JSON via stdout (empty if no releases)
# Returns: 0 on success or 404 (no releases), 1 on real API error
#######################################
_probe_github_release() {
	local slug="$1"
	local api_stderr
	api_stderr=$(mktemp -t upstream-watch-err.XXXXXX)
	local release_json=""

	if release_json=$(gh api "repos/${slug}/releases/latest" 2>"$api_stderr"); then
		rm -f "$api_stderr"
		printf '%s' "$release_json"
		return 0
	fi

	local release_err
	release_err=$(<"$api_stderr")
	rm -f "$api_stderr"

	# 404 = no releases (normal, not an error)
	if [[ "$release_err" == *"Not Found"* || "$release_err" == *"404"* ]]; then
		return 0
	fi

	_log_warn "gh api releases failed for ${slug}: ${release_err}"
	echo -e "${YELLOW}Warning${NC}: Could not fetch releases for ${slug}" >&2
	return 1
}

#######################################
# Probe GitHub API for the latest commit of a repository.
# Echoes commit JSON on success; empty string on error.
# Arguments:
#   $1 - Repository slug (owner/repo)
# Outputs: commit JSON via stdout (empty on error)
# Returns: 0 on success, 1 on API error
#######################################
_probe_github_commit() {
	local slug="$1"
	local api_stderr
	api_stderr=$(mktemp -t upstream-watch-err.XXXXXX)
	local commit_json=""

	if commit_json=$(gh api "repos/${slug}/commits?per_page=1" --jq '.[0]' 2>"$api_stderr"); then
		rm -f "$api_stderr"
		printf '%s' "$commit_json"
		return 0
	fi

	local commit_err
	commit_err=$(<"$api_stderr")
	rm -f "$api_stderr"

	_log_warn "gh api commits failed for ${slug}: ${commit_err}"
	echo -e "${YELLOW}Warning${NC}: Could not fetch commits for ${slug}" >&2
	return 1
}

# =============================================================================
# Update reporting
# =============================================================================

#######################################
# Report update status for a single GitHub repo and update shared counters.
# Arguments:
#   $1 - slug
#   $2 - relevance
#   $3 - has_new_release (true/false)
#   $4 - has_new_commits (true/false)
#   $5 - last_release_seen
#   $6 - last_commit_seen
#   $7 - latest_release_tag
#   $8 - latest_release_name
#   $9 - latest_release_date
#   $10 - latest_commit (full SHA)
#   $11 - latest_commit_date
#   $12 - verbose (true/false)
# Side-effects: increments _check_updates_found
#######################################
_report_github_repo_update() {
	local slug="$1"
	local relevance="$2"
	local has_new_release="$3"
	local has_new_commits="$4"
	local last_release_seen="$5"
	local last_commit_seen="$6"
	local latest_release_tag="$7"
	local latest_release_name="$8"
	local latest_release_date="$9"
	local latest_commit="${10}"
	local latest_commit_date="${11}"
	local verbose="${12}"

	if [[ "$has_new_release" == true ]]; then
		_check_updates_found=$((_check_updates_found + 1))
		echo ""
		echo -e "${YELLOW}NEW RELEASE${NC}: ${slug}"
		[[ -n "$relevance" ]] && echo -e "  Relevance: ${CYAN}${relevance}${NC}"
		echo "  Previous:  ${last_release_seen:-none}"
		echo "  Latest:    ${latest_release_tag} (${latest_release_date:-unknown})"
		[[ -n "$latest_release_name" && "$latest_release_name" != "$latest_release_tag" ]] &&
			echo "  Name:      ${latest_release_name}"
		_show_release_diff "$slug" "$last_release_seen" "$latest_release_tag"
		if [[ "$verbose" == true ]]; then
			_show_commit_diff "$slug" "$last_commit_seen" "${latest_commit:0:7}"
		fi
		echo "  Action:    Review changes, then run: upstream-watch-helper.sh ack ${slug}"
	elif [[ "$has_new_commits" == true ]]; then
		_check_updates_found=$((_check_updates_found + 1))
		echo ""
		echo -e "${BLUE}NEW COMMITS${NC}: ${slug} (no new release)"
		[[ -n "$relevance" ]] && echo -e "  Relevance: ${CYAN}${relevance}${NC}"
		if [[ "$verbose" == true ]]; then
			_show_commit_diff "$slug" "$last_commit_seen" "${latest_commit:0:7}"
		else
			echo "  Latest commit: ${latest_commit:0:7} (${latest_commit_date:-unknown})"
			echo "  Action:        Review changes, then run: upstream-watch-helper.sh ack ${slug}"
		fi
	else
		echo -e "${GREEN}Up to date${NC}: ${slug} (${latest_release_tag:-no releases})"
	fi
	return 0
}

# =============================================================================
# Diff display
# =============================================================================

#######################################
# Display release changelog between two tags
# Shows all releases between from_tag and to_tag, plus latest release notes.
# Arguments:
#   $1 - Repository slug (owner/repo)
#   $2 - From tag (last seen, empty for first check)
#   $3 - To tag (latest release)
#######################################
_show_release_diff() {
	local slug="$1"
	local from_tag="$2"
	local to_tag="$3"

	if [[ -z "$from_tag" ]]; then
		# First time -- just show the latest release notes
		echo "  Release notes:"
		local body
		body=$(gh api "repos/${slug}/releases/latest" --jq '.body // "No release notes"' 2>/dev/null) || body="Could not fetch"
		sed -n '1,20{s/^/    /;p;}' <<<"$body"
		local line_count
		line_count=$(wc -l <<<"$body" | tr -d ' ')
		if [[ "$line_count" -gt 20 ]]; then
			echo "    ... (${line_count} lines total -- view full notes on GitHub)"
		fi
		return 0
	fi

	# Show all releases between from_tag and to_tag
	local releases
	releases=$(gh api --paginate "repos/${slug}/releases" --jq '.[].tag_name' 2>/dev/null) || {
		echo "  (Could not fetch release list)"
		return 0
	}

	# Find releases newer than from_tag
	local in_range=true
	local release_count=0
	echo "  Releases since ${from_tag}:"
	while IFS= read -r tag; do
		[[ -z "$tag" ]] && continue
		if [[ "$tag" == "$from_tag" ]]; then
			in_range=false
			continue
		fi
		if [[ "$in_range" == true ]]; then
			release_count=$((release_count + 1))
			# Get one-line summary for each release
			local rel_name rel_date
			rel_name=$(gh api "repos/${slug}/releases/tags/${tag}" --jq '.name // .tag_name' 2>/dev/null) || rel_name="$tag"
			rel_date=$(gh api "repos/${slug}/releases/tags/${tag}" --jq '.published_at // ""' 2>/dev/null) || rel_date=""
			local date_short="${rel_date:0:10}"
			echo "    ${tag} (${date_short}) -- ${rel_name}"
		fi
	done <<<"$releases"

	if [[ "$release_count" -eq 0 ]]; then
		echo "    (none found -- tags may not match release list)"
	fi

	# Show latest release notes
	echo ""
	echo "  Latest release notes (${to_tag}):"
	local body
	body=$(gh api "repos/${slug}/releases/tags/${to_tag}" --jq '.body // "No release notes"' 2>/dev/null) || body="Could not fetch"
	sed -n '1,30{s/^/    /;p;}' <<<"$body"
	local line_count
	line_count=$(wc -l <<<"$body" | tr -d ' ')
	if [[ "$line_count" -gt 30 ]]; then
		echo "    ... (${line_count} lines total)"
	fi
	return 0
}

#######################################
# Display recent commits between two SHAs
# Shows up to 10 commits newer than from_sha.
# Arguments:
#   $1 - Repository slug (owner/repo)
#   $2 - From SHA (7-char, last seen)
#   $3 - To SHA (7-char, latest)
#######################################
_show_commit_diff() {
	local slug="$1"
	local from_sha="$2"
	local to_sha="$3"

	if [[ -z "$from_sha" || "$from_sha" == "$to_sha" ]]; then
		return 0
	fi

	echo "  Recent commits:"
	local commits
	commits=$(gh api "repos/${slug}/commits?per_page=10" \
		--jq '.[] | "\(.sha[0:7]) \(.commit.message | split("\n")[0])"' 2>/dev/null) || {
		echo "    (Could not fetch commits)"
		return 0
	}

	local count=0
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local sha="${line%% *}"
		if [[ "$sha" == "$from_sha" ]]; then
			break
		fi
		count=$((count + 1))
		echo "    ${line}"
		if [[ "$count" -ge 10 ]]; then
			echo "    ... (showing first 10)"
			break
		fi
	done <<<"$commits"

	if [[ "$count" -eq 0 ]]; then
		echo "    (no new commits found in recent history)"
	fi
	return 0
}

# =============================================================================
# Single-repo check
# =============================================================================

#######################################
# Check a single GitHub repo according to its configured watch mode.
# Updates state in-place (passed by reference via global _check_state).
# Arguments:
#   $1 - Repository slug (owner/repo)
#   $2 - Config JSON
#   $3 - Current ISO timestamp
#   $4 - Verbose flag (true/false)
# Outputs: prints update report to stdout
# Returns: 0 if up to date or updated, 1 if probe failed
# Side-effects: sets _check_updates_found, _check_had_probe_failure globals
#######################################
_check_single_github_repo() {
	local slug="$1"
	local config="$2"
	local now="$3"
	local verbose="$4"

	local entry_json relevance watch_mode
	entry_json=$(printf '%s' "$config" | jq --arg slug "$slug" '.repos[] | select(.slug == $slug)')
	relevance=$(printf '%s' "$entry_json" | jq -r '.relevance // ""')
	watch_mode=$(printf '%s' "$entry_json" | jq -r --arg default_mode "$UPSTREAM_WATCH_MODE_RELEASES_AND_COMMITS" '.watch_mode // $default_mode')
	if ! _upstream_watch_mode_valid "$watch_mode"; then
		_log_warn "Invalid watch_mode '${watch_mode}' for ${slug}"
		echo -e "${RED}Error${NC}: Invalid watch_mode '${watch_mode}' for ${slug}; expected ${UPSTREAM_WATCH_MODE_RELEASES} or ${UPSTREAM_WATCH_MODE_RELEASES_AND_COMMITS}" >&2
		_check_had_probe_failure=true
		return 0
	fi

	if ! _initialize_github_repo_state "$slug" "$entry_json"; then
		_log_warn "Failed to initialize runtime state for ${slug}"
		_check_had_probe_failure=true
		return 0
	fi

	# Get last-seen state
	local last_release_seen last_commit_seen updates_pending_before
	last_release_seen=$(echo "$_check_state" | jq -r --arg slug "$slug" '.repos[$slug].last_release_seen // ""')
	last_commit_seen=$(echo "$_check_state" | jq -r --arg slug "$slug" '.repos[$slug].last_commit_seen // ""')
	updates_pending_before=$(echo "$_check_state" | jq -r --arg slug "$slug" '.repos[$slug].updates_pending // 0')

	# --- Check releases ---
	local release_json="" probe_failed=false
	local latest_release_tag="" latest_release_name="" latest_release_date=""
	if ! release_json=$(_probe_github_release "$slug"); then
		probe_failed=true
	fi
	if [[ -n "$release_json" ]]; then
		latest_release_tag=$(echo "$release_json" | jq -r '.tag_name // ""')
		latest_release_name=$(echo "$release_json" | jq -r '.name // ""')
		latest_release_date=$(echo "$release_json" | jq -r '.published_at // ""')
	fi

	local has_new_release=false
	if [[ -n "$latest_release_tag" && "$latest_release_tag" != "$last_release_seen" ]]; then
		has_new_release=true
	fi

	# --- Check commits when this entry opted into commit monitoring ---
	local commit_json="" latest_commit="" latest_commit_date=""
	local watch_commits=false
	if [[ "$watch_mode" == "$UPSTREAM_WATCH_MODE_RELEASES_AND_COMMITS" ]]; then
		watch_commits=true
		if ! commit_json=$(_probe_github_commit "$slug"); then
			probe_failed=true
		fi
		if [[ -n "$commit_json" ]]; then
			latest_commit=$(echo "$commit_json" | jq -r '.sha // ""')
			latest_commit_date=$(echo "$commit_json" | jq -r '.commit.committer.date // ""')
		fi
	fi

	local has_new_commits=false
	if [[ -n "$latest_commit" && "${latest_commit:0:7}" != "$last_commit_seen" ]]; then
		has_new_commits=true
	fi

	# --- Report ---
	local report_verbose="$verbose"
	[[ "$watch_commits" == false ]] && report_verbose=false
	_report_github_repo_update "$slug" "$relevance" \
		"$has_new_release" "$has_new_commits" \
		"$last_release_seen" "$last_commit_seen" \
		"$latest_release_tag" "$latest_release_name" "$latest_release_date" \
		"$latest_commit" "$latest_commit_date" "$report_verbose"

	# Update last_checked and updates_pending (not last_seen -- requires explicit ack)
	# Skip state update if probes failed to avoid masking errors as "up to date"
	if [[ "$probe_failed" != true ]]; then
		local new_pending
		new_pending=$([[ "$has_new_release" == true || "$has_new_commits" == true ]] && echo 1 || echo 0)
		_check_state=$(echo "$_check_state" | jq --arg slug "$slug" --arg now "$now" \
			--argjson pending "$new_pending" \
			'.repos[$slug].last_checked = $now | .repos[$slug].updates_pending = $pending')

		# Queue GitHub issue reporting on 0->1 transition (t2810/t22495)
		if [[ "$updates_pending_before" != "1" && "$new_pending" == "1" ]]; then
			local update_kind="commit"
			local update_old="$last_commit_seen"
			local update_new="${latest_commit:0:7}"
			if [[ "$has_new_release" == true ]]; then
				update_kind="release"
				update_old="$last_release_seen"
				update_new="$latest_release_tag"
			fi
			_queue_upstream_update_issue "$slug" "$update_kind" "$update_old" "$update_new" "$entry_json"
		fi
	else
		_check_had_probe_failure=true
	fi
	return 0
}

# =============================================================================
# Non-GitHub upstream checks
# =============================================================================

#######################################
# Check all non-GitHub upstreams (Docker Hub, GitLab, Forgejo, etc.)
# Updates _check_state in-place via global.
# Arguments:
#   $1 - Config JSON
#   $2 - Target name (empty = all)
#   $3 - Current ISO timestamp
# Side-effects: sets _check_updates_found, _check_had_probe_failure globals
#######################################
_check_non_github_upstreams() {
	local config="$1"
	local target_name="$2"
	local now="$3"

	local non_github_names
	if [[ -n "$target_name" ]]; then
		non_github_names="$target_name"
	else
		non_github_names=$(echo "$config" | jq -r '.non_github_upstreams // [] | .[].name')
	fi

	while IFS= read -r entry_name; do
		[[ -z "$entry_name" ]] && continue

		local entry_json
		entry_json=$(echo "$config" | jq --arg name "$entry_name" '.non_github_upstreams[] | select(.name == $name)')

		local check_cmd source_type description relevance entry_url
		check_cmd=$(echo "$entry_json" | jq -r '.check_command // ""')
		source_type=$(echo "$entry_json" | jq -r '.source_type // "unknown"')
		description=$(echo "$entry_json" | jq -r '.description // ""')
		relevance=$(echo "$entry_json" | jq -r '.relevance // ""')
		entry_url=$(echo "$entry_json" | jq -r '.url // ""')

		if [[ -z "$check_cmd" ]]; then
			echo -e "${YELLOW}Warning${NC}: No check_command for ${entry_name}, skipping" >&2
			continue
		fi

		# Get last-seen state
		local last_seen_value ng_updates_pending_before
		last_seen_value=$(echo "$_check_state" | jq -r --arg name "$entry_name" '.non_github[$name].last_seen // ""')
		ng_updates_pending_before=$(echo "$_check_state" | jq -r --arg name "$entry_name" '.non_github[$name].updates_pending // 0')

		# Run the check command (curl + jq) in a subshell for isolation
		# Note: check_command comes from a committed config file, not user input
		local current_value=""
		local probe_failed=false
		current_value=$(bash -c "$check_cmd" 2>/dev/null) || {
			_log_warn "check_command failed for ${entry_name}"
			echo -e "${YELLOW}Warning${NC}: Could not check ${entry_name} (${source_type})" >&2
			probe_failed=true
		}

		# Trim whitespace
		current_value=$(echo "$current_value" | tr -d '[:space:]')

		local has_update=false
		if [[ "$probe_failed" != true && -n "$current_value" && "$current_value" != "$last_seen_value" ]]; then
			has_update=true
		fi

		if [[ "$has_update" == true ]]; then
			_check_updates_found=$((_check_updates_found + 1))
			echo ""
			echo -e "${YELLOW}UPDATE DETECTED${NC}: ${entry_name} (${source_type})"
			echo "  Description: ${description}"
			[[ -n "$relevance" ]] && echo -e "  Relevance:   ${CYAN}${relevance}${NC}"
			echo "  Previous:    ${last_seen_value:-none}"
			echo "  Current:     ${current_value}"
			[[ -n "$entry_url" ]] && echo "  URL:         ${entry_url}"

			# Show affected files
			local affects
			affects=$(echo "$entry_json" | jq -r '.affects // [] | .[]' 2>/dev/null)
			if [[ -n "$affects" ]]; then
				echo "  Affects:"
				while IFS= read -r affected_file; do
					[[ -n "$affected_file" ]] && echo "    - ${affected_file}"
				done <<<"$affects"
			fi

			echo "  Action:      Review changes, then run: upstream-watch-helper.sh ack ${entry_name}"
		elif [[ "$probe_failed" != true ]]; then
			echo -e "${GREEN}Up to date${NC}: ${entry_name} (${source_type}: ${current_value:-unknown})"
		fi

		# Update state (but not last_seen -- that requires explicit ack)
		if [[ "$probe_failed" != true ]]; then
			local ng_new_pending
			ng_new_pending=$([[ "$has_update" == true ]] && echo 1 || echo 0)
			_check_state=$(echo "$_check_state" | jq --arg name "$entry_name" --arg now "$now" \
				--arg current "$current_value" \
				--argjson pending "$ng_new_pending" \
				'.non_github[$name].last_checked = $now | .non_github[$name].current_value = $current | .non_github[$name].updates_pending = $pending')

			# Queue GitHub issue reporting on 0->1 transition (t2810/t22495)
			if [[ "$ng_updates_pending_before" != "1" && "$ng_new_pending" == "1" ]]; then
				_queue_upstream_update_issue "$entry_name" "update" "$last_seen_value" "$current_value" "$entry_json"
			fi
		else
			_check_had_probe_failure=true
		fi

	done <<<"$non_github_names"
	return 0
}

# =============================================================================
# cmd_check
# =============================================================================

#######################################
# Check watched repos for new releases and commits
# Compares current GitHub state against last-seen state. Reports new
# releases with changelog diffs and new commits. Does NOT advance
# last_seen -- that requires explicit ack. Returns 1 if any probe failed.
# Also checks non-GitHub upstreams (Docker Hub, GitLab, Forgejo) via
# their configured check_command.
# Arguments:
#   $1 - Optional target slug/name to check a single repo
# Globals:
#   VERBOSE - Show commit-level detail when true
#######################################
cmd_check() {
	local target_slug="${1:-}"
	local verbose="${VERBOSE:-false}"

	_check_prerequisites || return 1

	local config
	config=$(_read_config)
	# Use a global so sub-functions can update state in-place
	_check_state=$(_read_state)

	# Check if target is a non-GitHub upstream name
	local target_is_non_github=false
	if [[ -n "$target_slug" ]]; then
		if echo "$config" | jq -e --arg name "$target_slug" '.non_github_upstreams // [] | .[] | select(.name == $name)' >/dev/null 2>&1; then
			target_is_non_github=true
		fi
	fi

	local slugs=""
	if [[ -n "$target_slug" && "$target_is_non_github" != true ]]; then
		# Validate that the target slug is on the GitHub watchlist
		if ! echo "$config" | jq -e --arg slug "$target_slug" '.repos[] | select(.slug == $slug)' >/dev/null 2>&1; then
			echo -e "${RED}Error: Not watching ${target_slug}. Add it first with 'upstream-watch-helper.sh add ${target_slug}'.${NC}" >&2
			return 1
		fi
		slugs="$target_slug"
	elif [[ "$target_is_non_github" != true ]]; then
		slugs=$(echo "$config" | jq -r '.repos[].slug')
	fi

	local has_github_repos=false
	local has_non_github=false
	[[ -n "$slugs" ]] && has_github_repos=true
	if echo "$config" | jq -e '.non_github_upstreams // [] | length > 0' >/dev/null 2>&1; then
		has_non_github=true
	fi

	if [[ "$has_github_repos" != true && "$has_non_github" != true ]]; then
		echo -e "${BLUE}No repos being watched. Use 'add' to start watching.${NC}"
		return 0
	fi

	# Shared counters updated by sub-functions
	_check_updates_found=0
	_check_had_probe_failure=false
	local issue_queue_file
	issue_queue_file=$(mktemp -t upstream-watch-issues.XXXXXX)
	_UPSTREAM_WATCH_ISSUE_QUEUE_FILE="$issue_queue_file"
	local now
	now=$(_now_iso)

	# Check GitHub repos
	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue
		_check_single_github_repo "$slug" "$config" "$now" "$verbose"
	done <<<"$slugs"

	# Check non-GitHub upstreams
	if [[ "$has_non_github" == true ]]; then
		local ng_target=""
		[[ "$target_is_non_github" == true ]] && ng_target="$target_slug"
		_check_non_github_upstreams "$config" "$ng_target" "$now"
	fi

	_flush_upstream_update_issue_queue "$issue_queue_file"
	rm -f "$issue_queue_file"
	unset _UPSTREAM_WATCH_ISSUE_QUEUE_FILE

	# Only advance global last_check if all probes succeeded -- partial failures
	# should not advance the 24h gate so the caller retries on the next cycle
	if [[ "$_check_had_probe_failure" != true ]]; then
		_check_state=$(echo "$_check_state" | jq --arg now "$now" '.last_check = $now')
	fi
	_write_state "$_check_state"

	echo ""
	if [[ "$_check_updates_found" -gt 0 ]]; then
		echo -e "${YELLOW}${_check_updates_found} repo(s) have updates to review.${NC}"
	else
		echo -e "${GREEN}All watched repos are up to date.${NC}"
	fi

	_log_info "Check complete: ${_check_updates_found} updates found"
	[[ "$_check_had_probe_failure" == true ]] && return 1
	return 0
}
