#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# profile-readme-helper.sh — Auto-update GitHub profile README with live stats
#
# Usage:
#   profile-readme-helper.sh init                  # Create profile repo, seed README, register
#   profile-readme-helper.sh update [--dry-run]    # Update README with live data
#   profile-readme-helper.sh generate              # Print generated stats section to stdout
#   profile-readme-helper.sh help
#
# Requires:
#   - screen-time-helper.sh (macOS screen time)
#   - contributor-activity-helper.sh (AI session time)
#   - jq, bc, git
#
# The profile repo README must contain marker comments:
#   <!-- STATS-START --> ... <!-- STATS-END -->
#   <!-- UPDATED-START --> ... <!-- UPDATED-END -->

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=portable-stat.sh
source "${SCRIPT_DIR}/portable-stat.sh"
METRICS_FILE="${HOME}/.aidevops/.agent-workspace/observability/metrics.jsonl"
OBS_DB_FILE="${HOME}/.aidevops/.agent-workspace/observability/llm-requests.db"
OPENCODE_DB_FILE="${HOME}/.local/share/opencode/opencode.db"
OPENCODE_ARCHIVE_DB_FILE="${HOME}/.local/share/opencode/opencode-archive.db"
CONTRIBUTIONS_START_MARKER='<!-- CONTRIBUTIONS-START -->'
CONTRIBUTIONS_END_MARKER='<!-- CONTRIBUTIONS-END -->'
PROFILE_UPDATE_LOCK_TOKEN=""
PROFILE_UPDATE_LOCK_GRACE_SECONDS="${AIDEVOPS_PROFILE_LOCK_GRACE_SECONDS:-30}"

# --- Serialize profile refreshes so scheduler overlap cannot duplicate scans/writes ---
_profile_update_lock_dir() {
	printf '%s\n' "${HOME}/.aidevops/cache/profile-readme-update.lock"
	return 0
}

_profile_lock_mtime() {
	local lock_dir="$1"
	local modified=""
	modified=$(_file_mtime_epoch "$lock_dir" 2>/dev/null || true)
	[[ "$modified" =~ ^[0-9]+$ ]] || modified=0
	printf '%s\n' "$modified"
	return 0
}

_profile_lock_owner() {
	local lock_dir="$1"
	local owner_line=""
	if [[ -f "${lock_dir}/owner" ]]; then
		IFS= read -r owner_line <"${lock_dir}/owner" || true
		printf '%s\n' "$owner_line"
	fi
	return 0
}

_acquire_profile_update_lock() {
	local lock_dir token now
	lock_dir=$(_profile_update_lock_dir)
	now=$(date +%s)
	token="$$.${RANDOM}.${now}.${RANDOM}"
	mkdir -p "${lock_dir%/*}" || return 1
	if mkdir "$lock_dir" 2>/dev/null; then
		local owner_tmp="${lock_dir}/owner.${token}"
		printf '%s|%s|%s\n' "$token" "$$" "$now" >"$owner_tmp" || return 1
		mv "$owner_tmp" "${lock_dir}/owner" || return 1
		PROFILE_UPDATE_LOCK_TOKEN="$token"
		return 0
	fi

	local owner_before owner_after lock_pid lock_created mtime_before mtime_after age
	owner_before=$(_profile_lock_owner "$lock_dir")
	mtime_before=$(_profile_lock_mtime "$lock_dir")
	IFS='|' read -r _ lock_pid lock_created <<<"$owner_before"
	age=$((now - mtime_before))
	if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
		echo "Profile README update already running; skipping overlapping refresh" >&2
		return 1
	fi
	if [[ -z "$owner_before" || ! "$lock_created" =~ ^[0-9]+$ ]] && [[ "$age" -lt "$PROFILE_UPDATE_LOCK_GRACE_SECONDS" ]]; then
		echo "Profile README lock is being initialized; skipping overlapping refresh" >&2
		return 1
	fi

	# Revalidate immediately before the atomic rename. A changed owner/mtime means
	# another process repaired or replaced the lock while this process inspected it.
	owner_after=$(_profile_lock_owner "$lock_dir")
	mtime_after=$(_profile_lock_mtime "$lock_dir")
	if [[ "$owner_before" != "$owner_after" || "$mtime_before" != "$mtime_after" ]]; then
		echo "Profile README lock changed during stale-owner validation" >&2
		return 1
	fi
	local stale_dir="${lock_dir}.stale.${token}"
	if ! mv "$lock_dir" "$stale_dir" 2>/dev/null; then
		echo "Profile README lock was claimed by another process" >&2
		return 1
	fi
	rm -rf "$stale_dir"
	if ! mkdir "$lock_dir" 2>/dev/null; then
		echo "Profile README update already running; skipping overlapping refresh" >&2
		return 1
	fi
	local owner_tmp="${lock_dir}/owner.${token}"
	printf '%s|%s|%s\n' "$token" "$$" "$now" >"$owner_tmp" || return 1
	mv "$owner_tmp" "${lock_dir}/owner" || return 1
	PROFILE_UPDATE_LOCK_TOKEN="$token"
	return 0
}

_release_profile_update_lock() {
	local lock_dir
	lock_dir=$(_profile_update_lock_dir)
	if [[ -z "$PROFILE_UPDATE_LOCK_TOKEN" ]]; then
		return 0
	fi
	local owner token
	owner=$(_profile_lock_owner "$lock_dir")
	token="${owner%%|*}"
	if [[ "$token" != "$PROFILE_UPDATE_LOCK_TOKEN" ]]; then
		echo "Profile README lock owner changed; refusing non-owner release" >&2
		return 1
	fi
	rm -rf "$lock_dir"
	PROFILE_UPDATE_LOCK_TOKEN=""
	return 0
}

# --- Resolve profile repo path from repos.json ---
_resolve_profile_repo() {
	local repos_json="${HOME}/.config/aidevops/repos.json"

	# Try repos.json first (primary lookup)
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local profile_path
		profile_path=$(jq -r '
			(.initialized_repos // (to_entries | map(.value)))[]
			| select(.priority == "profile")
			| .path // empty
		' "$repos_json" | head -1)

		if [[ -n "$profile_path" && -d "$profile_path" ]]; then
			echo "$profile_path"
			return 0
		fi
	fi

	# Self-healing fallback: find profile repo by convention (~/Git/$username).
	# This handles the case where cmd_init created the repo but repos.json
	# registration failed or was lost. The hourly update job would otherwise
	# silently fail forever.
	local gh_user=""
	if command -v gh &>/dev/null; then
		gh_user=$(gh api user --jq '.login' 2>/dev/null) || true
	fi
	if [[ -z "$gh_user" ]]; then
		echo "Error: no profile repo in repos.json and gh CLI unavailable for fallback" >&2
		return 1
	fi

	local convention_path="${HOME}/Git/${gh_user}"
	if [[ -d "$convention_path" ]] && [[ -f "${convention_path}/README.md" ]]; then
		# Found it — auto-register in repos.json so future lookups are fast.
		# Don't require markers — cmd_init/cmd_update will inject them if missing.
		echo "Auto-registering profile repo at $convention_path" >&2
		if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
			local tmp_json
			tmp_json=$(mktemp)
			if jq --arg path "$convention_path" --arg slug "${gh_user}/${gh_user}" '
				.initialized_repos += [{
					"path": $path,
					"slug": $slug,
					"priority": "profile",
					"pulse": false,
					"maintainer": ($slug | split("/")[0])
				}]
			' "$repos_json" >"$tmp_json" && jq empty "$tmp_json" 2>/dev/null; then
				mv "$tmp_json" "$repos_json"
			else
				echo "ERROR: repos.json write produced invalid JSON — aborting (GH#16746)" >&2
				rm -f "$tmp_json"
			fi
		fi
		echo "$convention_path"
		return 0
	fi

	# Last resort: try cmd_init to create/clone/register everything
	if command -v gh &>/dev/null && gh auth status &>/dev/null; then
		echo "No profile repo found — running init to create one" >&2
		if cmd_init >&2; then
			# Re-resolve after init
			local init_path="${HOME}/Git/${gh_user}"
			if [[ -d "$init_path" ]]; then
				echo "$init_path"
				return 0
			fi
		fi
	fi

	echo "Error: no profile repo found and could not auto-create one" >&2
	return 1
}

# --- Source sub-libraries ---
# shellcheck source=profile-readme-data-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/profile-readme-data-lib.sh"
# shellcheck source=profile-readme-render-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/profile-readme-render-lib.sh"

# =============================================================================
# Profile README Management — Badges, README Generation, Clone/Init, Update
# =============================================================================

# --- Map language name to shields.io badge ---
_lang_badge() {
	local lang="$1"
	case "$lang" in
	Shell) echo '![Shell](https://img.shields.io/badge/-Shell-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)' ;;
	TypeScript) echo '![TypeScript](https://img.shields.io/badge/-TypeScript-3178C6?style=flat-square&logo=typescript&logoColor=white)' ;;
	JavaScript) echo '![JavaScript](https://img.shields.io/badge/-JavaScript-F7DF1E?style=flat-square&logo=javascript&logoColor=black)' ;;
	Python) echo '![Python](https://img.shields.io/badge/-Python-3776AB?style=flat-square&logo=python&logoColor=white)' ;;
	Ruby) echo '![Ruby](https://img.shields.io/badge/-Ruby-CC342D?style=flat-square&logo=ruby&logoColor=white)' ;;
	Go) echo '![Go](https://img.shields.io/badge/-Go-00ADD8?style=flat-square&logo=go&logoColor=white)' ;;
	Rust) echo '![Rust](https://img.shields.io/badge/-Rust-000000?style=flat-square&logo=rust&logoColor=white)' ;;
	Java) echo '![Java](https://img.shields.io/badge/-Java-007396?style=flat-square&logo=openjdk&logoColor=white)' ;;
	PHP) echo '![PHP](https://img.shields.io/badge/-PHP-777BB4?style=flat-square&logo=php&logoColor=white)' ;;
	C) echo '![C](https://img.shields.io/badge/-C-A8B9CC?style=flat-square&logo=c&logoColor=black)' ;;
	"C++") echo '![C++](https://img.shields.io/badge/-C++-00599C?style=flat-square&logo=cplusplus&logoColor=white)' ;;
	"C#") echo '![C#](https://img.shields.io/badge/-C%23-239120?style=flat-square&logo=csharp&logoColor=white)' ;;
	Swift) echo '![Swift](https://img.shields.io/badge/-Swift-FA7343?style=flat-square&logo=swift&logoColor=white)' ;;
	Kotlin) echo '![Kotlin](https://img.shields.io/badge/-Kotlin-7F52FF?style=flat-square&logo=kotlin&logoColor=white)' ;;
	Dart) echo '![Dart](https://img.shields.io/badge/-Dart-0175C2?style=flat-square&logo=dart&logoColor=white)' ;;
	HTML) echo '![HTML](https://img.shields.io/badge/-HTML-E34F26?style=flat-square&logo=html5&logoColor=white)' ;;
	CSS) echo '![CSS](https://img.shields.io/badge/-CSS-1572B6?style=flat-square&logo=css3&logoColor=white)' ;;
	Lua) echo '![Lua](https://img.shields.io/badge/-Lua-2C2D72?style=flat-square&logo=lua&logoColor=white)' ;;
	Elixir) echo '![Elixir](https://img.shields.io/badge/-Elixir-4B275F?style=flat-square&logo=elixir&logoColor=white)' ;;
	Scala) echo '![Scala](https://img.shields.io/badge/-Scala-DC322F?style=flat-square&logo=scala&logoColor=white)' ;;
	Haskell) echo '![Haskell](https://img.shields.io/badge/-Haskell-5D4F85?style=flat-square&logo=haskell&logoColor=white)' ;;
	Vue) echo '![Vue](https://img.shields.io/badge/-Vue-4FC08D?style=flat-square&logo=vuedotjs&logoColor=white)' ;;
	Svelte) echo '![Svelte](https://img.shields.io/badge/-Svelte-FF3E00?style=flat-square&logo=svelte&logoColor=white)' ;;
	*) echo "![${lang}](https://img.shields.io/badge/-${lang// /%20}-555555?style=flat-square)" ;;
	esac
	return 0
}

# --- Sanitize a string for safe use in markdown ---
# Strips characters that could break markdown link/image syntax
_sanitize_md() {
	local input="$1"
	# Remove markdown-breaking characters: [ ] ( ) and backticks
	local sanitized
	sanitized="${input//[\[\]()]/}"
	sanitized="${sanitized//\`/}"
	echo "$sanitized"
	return 0
}

# --- Validate a URL for safe embedding in markdown ---
# Rejects javascript: URIs, non-http(s) schemes, and markdown-breaking chars
_sanitize_url() {
	local url="$1"
	# Must start with http:// or https:// (case-insensitive)
	local url_lower
	url_lower=$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')
	if [[ "$url_lower" != http://* && "$url_lower" != https://* ]]; then
		echo ""
		return 0
	fi
	# Reject URLs containing markdown-breaking characters or whitespace
	if [[ "$url" == *'('* || "$url" == *')'* || "$url" == *'['* || "$url" == *']'* || "$url" == *' '* ]]; then
		echo ""
		return 0
	fi
	echo "$url"
	return 0
}

# --- Resolve GitHub username for profile repo ---
_resolve_profile_user() {
	local profile_repo="$1"

	# Try origin remote first (owner/repo)
	local origin_url
	origin_url=$(git -C "$profile_repo" remote get-url origin 2>/dev/null || true)
	if [[ -n "$origin_url" ]]; then
		local slug
		slug=$(echo "$origin_url" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
		local owner repo
		owner="${slug%%/*}"
		repo="${slug##*/}"
		if [[ -n "$owner" && "$owner" == "$repo" ]]; then
			echo "$owner"
			return 0
		fi
	fi

	# Fallback to directory basename
	local base
	base=$(basename "$profile_repo")
	if [[ -n "$base" ]]; then
		echo "$base"
		return 0
	fi

	echo ""
	return 0
}

# --- Normalize README for no-op comparison ---
# Strips UPDATED and CONTRIBUTIONS blocks so timestamp/contribution changes
# don't suppress real stats diffs (and vice versa).
_normalize_readme_for_compare() {
	local file="$1"
	awk '
		/<!-- UPDATED-START -->/ { print; skip = 1; next }
		/<!-- UPDATED-END -->/ { skip = 0; print; next }
		/<!-- CONTRIBUTIONS-START -->/ { print; skip = 1; next }
		/<!-- CONTRIBUTIONS-END -->/ { skip = 0; print; next }
		!skip { print }
	' "$file"
	return 0
}

# --- Fetch and validate one contribution record ---
# Prints a sanitized tab-separated name, description, and URL. API failures and
# malformed responses fail closed so error payloads can never become Markdown.
_fetch_contribution_record() {
	local endpoint="$1"
	local jq_filter="$2"
	local context="$3"
	local record=""
	local malformed_warning="Warning: malformed GitHub API response for ${context}"

	if ! record=$(gh api "$endpoint" --jq "$jq_filter" 2>/dev/null); then
		echo "Warning: GitHub API failed for ${context}" >&2
		return 1
	fi
	if [[ -z "$record" || "$record" == *$'\n'* ]]; then
		echo "$malformed_warning" >&2
		return 1
	fi

	local name="${record%%$'\t'*}"
	local remainder="${record#*$'\t'}"
	if [[ "$remainder" == "$record" ]]; then
		echo "$malformed_warning" >&2
		return 1
	fi
	local description="${remainder%%$'\t'*}"
	local url="${remainder#*$'\t'}"
	if [[ "$url" == "$remainder" || "$url" == *$'\t'* ]]; then
		echo "$malformed_warning" >&2
		return 1
	fi
	name=$(_sanitize_md "$name")
	description=$(_sanitize_md "$description")
	url=$(_sanitize_url "$url")
	if [[ "$name" == *'<'* || "$name" == *'>'* || "$description" == *'<'* || "$description" == *'>'* ]]; then
		echo "Warning: unsafe GitHub API record for ${context}" >&2
		return 1
	fi
	if [[ -z "$name" || -z "$url" ]]; then
		echo "Warning: invalid GitHub API record for ${context}" >&2
		return 1
	fi
	[[ -n "$description" ]] || description="No description"
	printf '%s\t%s\t%s\n' "$name" "$description" "$url"
	return 0
}

# --- List and validate fork names for the profile user ---
_list_profile_fork_names() {
	local gh_user="$1"
	local repos_json=""
	if ! repos_json=$(gh api "users/${gh_user}/repos?per_page=100&sort=updated" --paginate 2>/dev/null); then
		echo "Warning: GitHub API failed while listing profile repositories" >&2
		return 1
	fi
	if ! printf '%s\n' "$repos_json" | jq -e -s '
		length > 0 and all(.[];
			type == "array" and all(.[];
				type == "object"
				and (.fork | type) == "boolean"
				and (.name | type) == "string"
			)
		)
	' >/dev/null 2>&1; then
		echo "Warning: malformed GitHub API repository list" >&2
		return 1
	fi
	if ! printf '%s\n' "$repos_json" | jq -r '.[] | select(.fork == true) | .name'; then
		echo "Warning: could not parse GitHub API repository list" >&2
		return 1
	fi
	return 0
}

# --- Generate contributions list from forks + repos.json contributed entries ---
# Outputs markdown lines (one per contributed repo), or empty string if none.
# Uses core API only (no search API) — ~11 sequential calls per run. Sequential
# collection prevents concurrent gh output streams from interleaving.
# Deduplicates across all sources using a newline-delimited "seen" list with
# exact matching (bash 3.2 compatible — no associative arrays).
_generate_contributions() {
	local gh_user="$1"
	local contrib_repos=""
	# Newline-delimited list of repo names already added (for O(1)-ish dedup).
	# Each entry is stored as a full line for exact grep -x matching, avoiding
	# false positives from partial name matches (e.g., "app" vs "webapp").
	local seen_repos=""

	# Source 1: forks — resolve parent URLs
	local fork_names
	fork_names=$(_list_profile_fork_names "$gh_user") || return 1
	if [[ -n "$fork_names" ]]; then
		local fork_filter
		fork_filter='"\(.name // "")\t\((.description // "No description") | gsub("[\\t\\n\\r]"; " "))\t\(.parent.html_url // "")"'
		while IFS= read -r fork_name; do
			[[ -z "$fork_name" ]] && continue
			local fork_record
			fork_record=$(_fetch_contribution_record "repos/${gh_user}/${fork_name}" "$fork_filter" "fork ${fork_name}") || return 1
			local rname rdesc rurl
			IFS=$'\t' read -r rname rdesc rurl <<<"$fork_record"
			if [[ -n "$seen_repos" ]] && grep -qxF -- "$rname" <<<"$seen_repos" 2>/dev/null; then
				continue
			fi
			seen_repos="${seen_repos}${rname}"$'\n'
			contrib_repos="${contrib_repos}- **[${rname}](${rurl})** -- ${rdesc}"$'\n'
		done <<<"$fork_names"
	fi

	# Source 2: repos.json "contributed: true" entries (non-fork contributions)
	local repos_config="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_config" ]] && command -v jq &>/dev/null; then
		local contributed_slugs
		if ! contributed_slugs=$(jq -r '
			(.initialized_repos // (to_entries | map(.value)))[]
			| select(.contributed == true)
			| .slug // empty
		' "$repos_config" 2>/dev/null); then
			echo "Warning: could not parse contributed repositories config" >&2
			return 1
		fi

		local repo_filter
		repo_filter='"\(.name // "")\t\((.description // "No description") | gsub("[\\t\\n\\r]"; " "))\t\(.html_url // "")"'
		while IFS= read -r slug; do
			[[ -z "$slug" ]] && continue
			local repo_name
			repo_name="${slug##*/}"
			# Deduplicate against all previously seen repos (forks + earlier entries)
			if [[ -n "$seen_repos" ]] && grep -qxF -- "$repo_name" <<<"$seen_repos" 2>/dev/null; then
				continue
			fi
			local repo_record desc url
			repo_record=$(_fetch_contribution_record "repos/${slug}" "$repo_filter" "repository ${slug}") || return 1
			IFS=$'\t' read -r repo_name desc url <<<"$repo_record"
			seen_repos="${seen_repos}${repo_name}"$'\n'
			contrib_repos="${contrib_repos}- **[${repo_name}](${url})** -- ${desc}"$'\n'
		done <<<"$contributed_slugs"
	fi

	# Sort alphabetically for deterministic output (prevents unnecessary commits
	# when the API returns results in a different order)
	if [[ -n "$contrib_repos" ]]; then
		contrib_repos=$(printf '%s' "$contrib_repos" | sort -f)
		# Ensure trailing newline
		contrib_repos="${contrib_repos}"$'\n'
	fi

	printf '%s' "$contrib_repos"
	return 0
}

# --- Generate contributions for a new rich README without blocking init ---
_generate_initial_contributions() {
	local gh_user="$1"
	local contributions=""
	if ! contributions=$(_generate_contributions "$gh_user"); then
		echo "Warning: initial Contributions block omitted because GitHub data was unavailable" >&2
		return 0
	fi
	printf '%s' "$contributions"
	return 0
}

# --- Detect if a README is the default GitHub profile template ---
# Returns 0 (true) if the file matches the default template pattern.
# The default template contains "## Hi there" and the commented-out suggestions
# block that GitHub auto-generates for new username/username repos.
_is_default_github_template() {
	local readme_path="$1"
	if [[ ! -f "$readme_path" ]]; then
		return 1
	fi
	# Check for the distinctive GitHub default template markers:
	# 1. The "Hi there" heading (with or without emoji)
	# 2. The commented-out "is a special repository" block
	if grep -q 'Hi there' "$readme_path" 2>/dev/null &&
		grep -q 'is a.*special.*repository' "$readme_path" 2>/dev/null; then
		return 0
	fi
	# Also match minimal default READMEs that just have "# username" and nothing else
	local line_count
	line_count=$(wc -l <"$readme_path" | tr -d ' ')
	if [[ "$line_count" -le 3 ]] && ! grep -q '<!-- STATS-START -->' "$readme_path" 2>/dev/null; then
		return 0
	fi
	return 1
}

# --- Inject aidevops markers into an existing README that lacks them ---
# Preserves all existing content and appends marker blocks at the end.
# This handles the case where a user has manually written their README
# (or GitHub created the default template) and we need to add our stats.
_inject_markers_into_readme() {
	local readme_path="$1"
	local tmp_file
	tmp_file=$(mktemp)

	# Copy existing content
	cat "$readme_path" >"$tmp_file"

	# Ensure trailing newline before appending
	if [[ -s "$tmp_file" ]] && [[ "$(tail -c 1 "$tmp_file" | wc -l)" -eq 0 ]]; then
		echo "" >>"$tmp_file"
	fi

	# Append marker blocks
	{
		echo ""
		echo "<!-- STATS-START -->"
		echo "<!-- Stats will be populated on next update -->"
		echo "<!-- STATS-END -->"
		echo ""
		echo "<!-- CONTRIBUTIONS-START -->"
		echo "<!-- CONTRIBUTIONS-END -->"
		echo ""
		echo "---"
		echo ""
		echo "<!-- UPDATED-START -->"
		echo "<!-- UPDATED-END -->"
	} >>"$tmp_file"

	mv "$tmp_file" "$readme_path"
	return 0
}

# --- Recover from diverged git history on the profile repo ---
# When the remote repo was deleted and recreated, the local clone has a
# different history. This function re-clones the repo and re-seeds the README.
_recover_diverged_profile() {
	local repo_dir="$1"
	local repo_slug="$2"
	local default_branch="$3"
	local gh_user="$4"

	echo "Recovering profile repo from diverged history..." >&2

	# Back up the local directory and re-clone
	local backup_dir="${repo_dir}.bak.$$"
	mv "$repo_dir" "$backup_dir"

	if git clone "git@github.com:${repo_slug}.git" "$repo_dir" 2>/dev/null ||
		git clone "https://github.com/${repo_slug}.git" "$repo_dir" 2>/dev/null; then
		# Re-seed the README with markers
		local readme_path="${repo_dir}/README.md"
		if [[ -f "$readme_path" ]] && grep -q '<!-- STATS-START -->' "$readme_path" 2>/dev/null; then
			echo "Remote README already has markers — no seeding needed"
		elif [[ ! -f "$readme_path" ]] || _is_default_github_template "$readme_path"; then
			echo "Creating rich profile README..."
			_generate_rich_readme "$gh_user" "$readme_path"
		elif [[ -f "$readme_path" ]]; then
			echo "Injecting markers into remote README..."
			_inject_markers_into_readme "$readme_path"
		fi

		# Commit and push the seeded README
		if [[ -n "$(git -C "$repo_dir" status --porcelain README.md 2>/dev/null)" ]]; then
			git -C "$repo_dir" add README.md
			git -C "$repo_dir" commit -m "feat: initialize profile README with aidevops stat markers" --no-verify 2>/dev/null || true
			git -C "$repo_dir" push origin "$default_branch" 2>/dev/null || {
				echo "Warning: push failed after re-clone — push manually" >&2
			}
		fi

		# Clean up backup
		rm -rf "$backup_dir"
		echo "Profile repo recovered successfully"
	else
		# Re-clone failed — restore backup
		echo "Error: re-clone failed — restoring backup" >&2
		rm -rf "$repo_dir"
		mv "$backup_dir" "$repo_dir"
	fi

	return 0
}

# --- Build language + tooling badge line for a user's repos ---
# Usage: _build_readme_badges <repos_json>
# Outputs badge markdown lines (one per badge).
_build_readme_badges() {
	local repos_json="$1"

	local languages
	languages=$(echo "$repos_json" | jq -r '[.[].language | select(. != null)] | unique | .[]')

	local badges=""
	while IFS= read -r lang; do
		[[ -z "$lang" ]] && continue
		local badge
		badge=$(_lang_badge "$lang")
		badges="${badges}${badge}"$'\n'
	done <<<"$languages"
	# Always add common tooling badges
	badges="${badges}"'![Docker](https://img.shields.io/badge/-Docker-2496ED?style=flat-square&logo=docker&logoColor=white)'$'\n'
	badges="${badges}"'![Linux](https://img.shields.io/badge/-Linux-FCC624?style=flat-square&logo=linux&logoColor=black)'$'\n'
	badges="${badges}"'![Git](https://img.shields.io/badge/-Git-F05032?style=flat-square&logo=git&logoColor=white)'$'\n'

	printf '%s' "$badges"
	return 0
}

# --- Build the Connect section badges for a user ---
# Usage: _build_readme_connect <gh_user> <blog> <twitter>
# Outputs badge markdown lines.
_build_readme_connect() {
	local gh_user="$1"
	local blog="$2"
	local twitter="$3"

	local connect=""
	if [[ -n "$blog" ]]; then
		local blog_display
		blog_display="${blog##*//}"
		blog_display=$(_sanitize_md "$blog_display")
		connect="${connect}[![Website](https://img.shields.io/badge/-${blog_display}-FF5722?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0id2hpdGUiIGQ9Ik0xMiAyQzYuNDggMiAyIDYuNDggMiAxMnM0LjQ4IDEwIDEwIDEwIDEwLTQuNDggMTAtMTBTMTcuNTIgMiAxMiAyem0tMSAxNy45M2MtMy45NS0uNDktNy0zLjg1LTctNy45MyAwLS42Mi4wOC0xLjIxLjIxLTEuNzlMOSAxNXY1YzAgLjU1LjQ1IDEgMSAxdjEuOTN6bTYuOS0yLjU0Yy0uMjYtLjgxLTEtMS4zOS0xLjktMS4zOWgtMXYtM2MwLS41NS0uNDUtMS0xLTFIOHYtMmgyYy41NSAwIDEtLjQ1IDEtMVY3aDJjMS4xIDAgMi0uOSAyLTJ2LS40MWMyLjkzIDEuMTkgNSA0LjA2IDUgNy40MSAwIDIuMDgtLjggMy45Ny0yLjEgNS4zOXoiLz48L3N2Zz4=&logoColor=white)](${blog})"$'\n'
	fi
	if [[ -n "$twitter" ]]; then
		connect="${connect}[![X](https://img.shields.io/badge/-@${twitter}-000000?style=flat-square&logo=x&logoColor=white)](https://twitter.com/${twitter})"$'\n'
	fi
	connect="${connect}[![GitHub](https://img.shields.io/badge/-Follow-181717?style=flat-square&logo=github&logoColor=white)](https://github.com/${gh_user})"$'\n'

	printf '%s' "$connect"
	return 0
}

# --- Build the commit-history chart for a user ---
# Usage: _build_commit_history_chart <gh_user>
# Outputs a centered light/dark picture without a clickable provider backlink.
_build_commit_history_chart() {
	local gh_user="$1"
	gh_user="${gh_user//[^a-zA-Z0-9-]/}"
	if [[ -z "$gh_user" ]]; then
		return 0
	fi

	cat <<EOF
<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://commit-history.com/embed/${gh_user}?theme=dark" />
    <img alt="${gh_user}'s commit history" src="https://commit-history.com/embed/${gh_user}" />
  </picture>
</div>
EOF
	return 0
}

# --- Append the commit-history chart to an older aidevops-generated README ---
# Usage: _ensure_commit_history_chart <readme_path> <gh_user>
_ensure_commit_history_chart() {
	local readme_path="$1"
	local gh_user="$2"
	if ! grep -Fq '> Stats auto-updated by [aidevops]' "$readme_path" 2>/dev/null; then
		return 0
	fi
	if grep -Fq 'https://commit-history.com/embed/' "$readme_path" 2>/dev/null; then
		return 0
	fi

	local commit_history_chart
	commit_history_chart=$(_build_commit_history_chart "$gh_user")
	if [[ -z "$commit_history_chart" ]]; then
		return 0
	fi
	printf '\n%s\n' "$commit_history_chart" >>"$readme_path"
	return 0
}

# --- Generate rich profile README from GitHub data ---
_generate_rich_readme() {
	local gh_user="$1"
	local readme_path="$2"

	# Fetch user profile — single jq pass for all fields
	local user_json
	user_json=$(gh api "users/${gh_user}") || user_json="{}"
	local display_name bio blog twitter
	IFS=$'\t' read -r display_name bio blog twitter < <(
		echo "$user_json" | jq -r '[
			((.name // "") | gsub("[\\t\\n]"; " ")),
			((.bio // "") | gsub("[\\t\\n]"; " ")),
			(if .blog != null and .blog != "" then (.blog | gsub("[\\t\\n]"; "")) else "" end),
			(if .twitter_username != null and .twitter_username != "" then (.twitter_username | gsub("[\\t\\n]"; "")) else "" end)
		] | join("\t")' || printf '\t\t\t\n'
	)
	display_name="${display_name:-$gh_user}"

	# Sanitize user-controlled fields
	display_name=$(_sanitize_md "$display_name")
	bio=$(_sanitize_md "$bio")
	blog=$(_sanitize_url "$blog")
	# twitter is used as a path component, strip non-alphanumeric/underscore
	twitter="${twitter//[^a-zA-Z0-9_]/}"

	# Fetch repos and detect languages
	local repos_json
	repos_json=$(gh api "users/${gh_user}/repos?per_page=100&sort=updated" --paginate) || repos_json="[]"

	# Build badge line and connect section via helpers
	local badges
	badges=$(_build_readme_badges "$repos_json")

	# Build own repos section — single jq pass (no loop)
	local own_repos
	own_repos=$(echo "$repos_json" | jq -r --arg user "$gh_user" '
		[.[] | select(.fork == false and .name != $user)] |
		map("- **[\(.name | gsub("[\\[\\]()`]"; ""))](\(.html_url))** -- \((.description // "No description") | gsub("[\\[\\]()`]"; ""))") |
		.[]
	')

	# Build contributions section using shared helper
	local contrib_repos
	contrib_repos=$(_generate_initial_contributions "$gh_user")

	# Build connect section
	local connect
	connect=$(_build_readme_connect "$gh_user" "$blog" "$twitter")
	local commit_history_chart
	commit_history_chart=$(_build_commit_history_chart "$gh_user")

	# Compose the README
	{
		echo "# ${display_name}"
		echo ""
		if [[ -n "$bio" ]]; then
			echo "**${bio}**"
			echo ""
		fi
		# Badges
		printf '%s' "$badges"
		echo ""
		echo "> Shipping with AI agents around the clock -- human hours for thinking, machine hours for doing."
		echo ">"
		echo "> Stats auto-updated by [aidevops](https://aidevops.sh)."
		echo ""
		echo "<!-- STATS-START -->"
		echo "<!-- Stats will be populated on first update -->"
		echo "<!-- STATS-END -->"
		echo ""
		# Own repos
		if [[ -n "$own_repos" ]]; then
			echo "## Projects"
			echo ""
			printf '%s' "$own_repos"
			echo ""
		fi
		# Contributions (auto-updated daily)
		echo "<!-- CONTRIBUTIONS-START -->"
		if [[ -n "$contrib_repos" ]]; then
			echo "## Contributions"
			echo ""
			printf '%s\n' "$contrib_repos"
		fi
		echo "<!-- CONTRIBUTIONS-END -->"
		echo ""
		# Connect
		echo "## Connect"
		echo ""
		printf '%s' "$connect"
		echo ""
		echo "---"
		echo ""
		echo "<!-- UPDATED-START -->"
		echo "<!-- UPDATED-END -->"
		echo ""
		printf '%s\n' "$commit_history_chart"
	} >"$readme_path"

	return 0
}

# --- Clone or pull the profile repo to a local directory ---
# Usage: _init_clone_or_pull <repo_slug> <repo_dir>
# Returns 0 on success, 1 on failure.
_init_clone_or_pull() {
	local repo_slug="$1"
	local repo_dir="$2"

	if [[ ! -d "$repo_dir" ]]; then
		echo "Cloning $repo_slug to $repo_dir"
		git clone "git@github.com:${repo_slug}.git" "$repo_dir" 2>/dev/null ||
			git clone "https://github.com/${repo_slug}.git" "$repo_dir" || {
			echo "Error: failed to clone $repo_slug" >&2
			return 1
		}
	else
		echo "Local repo already exists at $repo_dir"
		local init_branch
		init_branch=$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
		if [[ -z "$init_branch" ]]; then
			init_branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null || true)
		fi
		init_branch="${init_branch:-main}"
		git -C "$repo_dir" pull --ff-only origin "$init_branch" 2>/dev/null || true
	fi
	return 0
}

# --- Register or update the profile repo entry in repos.json ---
# Usage: _init_register_repos_json <repos_json> <repo_dir> <repo_slug>
_init_register_repos_json() {
	local repos_json="$1"
	local repo_dir="$2"
	local repo_slug="$3"

	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		return 0
	fi

	local already_registered
	already_registered=$(jq -r --arg path "$repo_dir" '
		if .initialized_repos then
			[.initialized_repos[] | select(.path == $path)] | length
		else
			[to_entries[] | select(.value.path == $path)] | length
		end
	' "$repos_json" 2>/dev/null)

	local tmp_json
	tmp_json=$(mktemp)
	if [[ "$already_registered" == "0" ]]; then
		echo "Registering profile repo in repos.json"
		if jq --arg path "$repo_dir" --arg slug "$repo_slug" '
			.initialized_repos += [{
				"path": $path,
				"slug": $slug,
				"priority": "profile",
				"pulse": false,
				"maintainer": ($slug | split("/")[0])
			}]
		' "$repos_json" >"$tmp_json" && jq empty "$tmp_json" 2>/dev/null; then
			mv "$tmp_json" "$repos_json"
		else
			echo "ERROR: repos.json write produced invalid JSON — aborting (GH#16746)" >&2
			rm -f "$tmp_json"
		fi
	else
		# Ensure priority is set to "profile"
		if jq --arg path "$repo_dir" '
			.initialized_repos |= map(
				if .path == $path then .priority = "profile" else . end
			)
		' "$repos_json" >"$tmp_json" && jq empty "$tmp_json" 2>/dev/null; then
			mv "$tmp_json" "$repos_json"
		else
			echo "ERROR: repos.json write produced invalid JSON — aborting (GH#16746)" >&2
			rm -f "$tmp_json"
		fi
	fi
	return 0
}

# --- Check if profile repo is already fully initialized ---
# Usage: _init_check_already_initialized <repos_json> <repo_slug> <gh_user> <default_repo_dir>
# Prints the effective repo_dir to stdout (may differ from default if repos.json has a path).
# Exit codes: 0 = already done (caller should return 0), 1 = not done (caller should continue),
#             2 = recovered from diverged history (caller should return 0).
_init_check_already_initialized() {
	local repos_json="$1"
	local repo_slug="$2"
	local gh_user="$3"
	local default_repo_dir="$4"

	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "$default_repo_dir"
		return 1
	fi

	local existing_profile
	existing_profile=$(jq -r '
		if .initialized_repos then
			.initialized_repos[] | select(.priority == "profile") | .path // empty
		else
			to_entries[] | select(.value.priority == "profile") | .value.path // empty
		end
	' "$repos_json" | head -1)

	if [[ -z "$existing_profile" ]]; then
		echo "$default_repo_dir"
		return 1
	fi

	if [[ -d "$existing_profile" ]] &&
		[[ -f "${existing_profile}/README.md" ]] &&
		grep -q '<!-- STATS-START -->' "${existing_profile}/README.md" 2>/dev/null; then
		# Local looks good — verify we can still push (catches diverged history)
		if git -C "$existing_profile" fetch origin 2>/dev/null; then
			local local_head remote_head merge_base
			local_head=$(git -C "$existing_profile" rev-parse HEAD 2>/dev/null || true)
			remote_head=$(git -C "$existing_profile" rev-parse FETCH_HEAD 2>/dev/null || true)
			if [[ -n "$local_head" && -n "$remote_head" ]]; then
				merge_base=$(git -C "$existing_profile" merge-base "$local_head" "$remote_head" 2>/dev/null || true)
				if [[ -z "$merge_base" ]]; then
					echo "Diverged history detected — re-initializing profile repo..." >&2
					_recover_diverged_profile "$existing_profile" "$repo_slug" "main" "$gh_user"
					echo "Profile repo recovered at $existing_profile" >&2
					echo "$existing_profile"
					return 2
				fi
			fi
		fi
		echo "Profile repo already initialized at $existing_profile" >&2
		echo "$existing_profile"
		return 0
	fi

	# Use existing path if directory exists (may just need README seeding)
	if [[ -d "$existing_profile" ]]; then
		echo "$existing_profile"
	else
		echo "$default_repo_dir"
	fi
	return 1
}

# --- Initialize profile README repo ---
# Creates the username/username GitHub repo if it doesn't exist, clones it,
# seeds a starter README with stat markers, and registers it in repos.json.
cmd_init() {
	# Require gh CLI
	if ! command -v gh &>/dev/null; then
		echo "Error: gh CLI required. Install from https://cli.github.com" >&2
		return 1
	fi

	# Get GitHub username
	local gh_user
	gh_user=$(gh api user --jq '.login' 2>/dev/null) || {
		echo "Error: not authenticated with gh CLI. Run 'gh auth login' first." >&2
		return 1
	}

	local repo_slug="${gh_user}/${gh_user}"
	local repos_json="${HOME}/.config/aidevops/repos.json"

	# Check if already fully initialized
	local repo_dir
	repo_dir=$(_init_check_already_initialized "$repos_json" "$repo_slug" "$gh_user" "${HOME}/Git/${gh_user}")
	local check_rc=$?
	if [[ "$check_rc" -eq 0 || "$check_rc" -eq 2 ]]; then
		return 0
	fi

	# Create the repo on GitHub if it doesn't exist
	if ! gh repo view "$repo_slug" &>/dev/null; then
		echo "Creating GitHub profile repo: $repo_slug"
		gh repo create "$repo_slug" --public --add-readme --description "GitHub profile README" || {
			echo "Error: failed to create repo $repo_slug" >&2
			return 1
		}
		sleep 2
	else
		echo "GitHub repo $repo_slug already exists"
	fi

	# Clone or pull the local copy
	_init_clone_or_pull "$repo_slug" "$repo_dir" || return 1

	# Detect default branch for push operations
	local default_branch
	default_branch=$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
	if [[ -z "$default_branch" ]]; then
		default_branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null || true)
	fi
	default_branch="${default_branch:-main}"

	# Seed README.md with stat markers.
	local readme_path="${repo_dir}/README.md"
	if [[ ! -f "$readme_path" ]]; then
		echo "Creating rich profile README..."
		_generate_rich_readme "$gh_user" "$readme_path"
	elif _is_default_github_template "$readme_path"; then
		echo "Default GitHub template detected — replacing with rich profile README..."
		_generate_rich_readme "$gh_user" "$readme_path"
	elif ! grep -q '<!-- STATS-START -->' "$readme_path"; then
		echo "Injecting stat markers into existing README..."
		_inject_markers_into_readme "$readme_path"
	fi

	# Commit and push if there are changes
	if [[ -n "$(git -C "$repo_dir" status --porcelain README.md 2>/dev/null)" ]]; then
		git -C "$repo_dir" add README.md
		git -C "$repo_dir" commit -m "feat: initialize profile README with aidevops stat markers" --no-verify 2>/dev/null || true
		if ! git -C "$repo_dir" push origin "$default_branch" 2>/dev/null; then
			echo "Push failed — attempting recovery from diverged history..." >&2
			_recover_diverged_profile "$repo_dir" "$repo_slug" "$default_branch" "$gh_user"
		fi
	fi

	# Register in repos.json
	_init_register_repos_json "$repos_json" "$repo_dir" "$repo_slug"

	# Run first update
	echo "Running first stats update..."
	cmd_update

	echo ""
	echo "Profile README initialized at: https://github.com/${gh_user}"
	echo ""
	echo "IMPORTANT: To show this on your GitHub profile, visit:"
	echo "  https://github.com/${repo_slug}"
	echo "and click the 'Show on profile' button if prompted."
	echo ""
	echo "Stats will auto-update hourly (configured by setup.sh)."

	return 0
}

# --- Inject the UPDATED timestamp into a README file in-place ---
# Usage: _update_inject_timestamp <file>
# Replaces content between <!-- UPDATED-START --> and <!-- UPDATED-END --> markers.
_update_inject_timestamp() {
	local file="$1"
	if ! grep -q '<!-- UPDATED-START -->' "$file"; then
		return 0
	fi
	local updated_at
	updated_at=$(date -u +"%Y-%m-%d %H:%M UTC")
	local updated_tmp
	updated_tmp=$(mktemp)
	awk -v ts="$updated_at" '
		/<!-- UPDATED-START -->/ {
			print "<!-- UPDATED-START -->"
			skip = 1
			next
		}
		/<!-- UPDATED-END -->/ {
			skip = 0
			printf "_Stats auto-updated %s by [aidevops](https://aidevops.sh) pulse._\n", ts
			print "<!-- UPDATED-END -->"
			next
		}
		!skip { print }
	' "$file" >"$updated_tmp"
	mv "$updated_tmp" "$file"
	return 0
}

# --- Ensure STATS markers exist in a README, injecting or regenerating as needed ---
# Usage: _update_inject_markers_if_needed <profile_repo> <readme_path>
# Commits the injection to the profile repo if changes were made.
_update_inject_markers_if_needed() {
	local profile_repo="$1"
	local readme_path="$2"

	# Even if markers exist, check if the content outside them is the default
	# GitHub template. This handles the case where v3.1.87 injected markers into
	# the default template but didn't replace the template content itself.
	if _is_default_github_template "$readme_path"; then
		echo "Default GitHub template detected — replacing with rich profile README..."
		local gh_user
		gh_user=$(_resolve_profile_user "$profile_repo")
		if [[ -n "$gh_user" ]]; then
			_generate_rich_readme "$gh_user" "$readme_path"
		else
			echo "Could not resolve username — injecting markers only..."
			_inject_markers_into_readme "$readme_path"
		fi
		git -C "$profile_repo" add README.md
		git -C "$profile_repo" commit -m "feat: replace default GitHub template with rich profile README" --no-verify 2>/dev/null || true
		return 0
	fi

	if grep -q '<!-- STATS-START -->' "$readme_path" && grep -q '<!-- STATS-END -->' "$readme_path"; then
		return 0
	fi

	echo "Markers missing from README — injecting them..."
	_inject_markers_into_readme "$readme_path"
	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "feat: initialize profile README with aidevops stat markers" --no-verify 2>/dev/null || true
	return 0
}

# --- Push a profile repo commit, recovering from diverged history if needed ---
# Usage: _update_push_with_recovery <profile_repo> <commit_msg> [extra_args...]
# Returns 0 always (recovery is attempted on push failure).
_update_push_with_recovery() {
	local profile_repo="$1"
	local commit_msg="$2"
	shift 2
	local extra_args=("$@")

	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "$commit_msg" --no-verify 2>/dev/null || {
		echo "No changes to commit after profile README update"
		return 0
	}
	echo "Committed profile README update: $commit_msg"

	local default_branch
	default_branch=$(git -C "$profile_repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
	if [[ -z "$default_branch" ]]; then
		default_branch=$(git -C "$profile_repo" branch --show-current 2>/dev/null || true)
	fi
	default_branch="${default_branch:-main}"

	if ! git -C "$profile_repo" push origin "$default_branch" 2>/dev/null; then
		echo "Push failed — attempting recovery from diverged history..." >&2
		local gh_user
		gh_user=$(_resolve_profile_user "$profile_repo")
		if [[ -n "$gh_user" ]]; then
			local repo_slug="${gh_user}/${gh_user}"
			_recover_diverged_profile "$profile_repo" "$repo_slug" "$default_branch" "$gh_user"
			echo "Running fresh stats update after recovery..."
			cmd_update "${extra_args[@]}"
		else
			echo "Warning: push failed and could not resolve username for recovery" >&2
		fi
	else
		echo "Pushed profile README update to origin/${default_branch}"
	fi
	return 0
}

# --- Update the profile README ---
cmd_update() {
	local dry_run=false
	if [[ "${1:-}" == "--dry-run" ]]; then
		dry_run=true
	fi
	if [[ "${AIDEVOPS_PROFILE_UPDATE_LOCK_HELD:-0}" != "1" ]]; then
		_acquire_profile_update_lock || return 1
		export AIDEVOPS_PROFILE_UPDATE_LOCK_HELD=1
		trap _release_profile_update_lock EXIT
	fi
	echo "Profile README update started at $(date -u +%Y-%m-%dT%H:%M:%SZ) (dry_run=${dry_run})"

	# Resolve profile repo
	local profile_repo
	profile_repo=$(_resolve_profile_repo) || return 1
	local readme_path="${profile_repo}/README.md"

	if [[ ! -f "$readme_path" ]]; then
		echo "Error: README.md not found at $readme_path" >&2
		return 1
	fi

	# Generate new stats section
	local new_stats
	new_stats=$(cmd_generate)

	# Daily contributions refresh — piggyback on the hourly stats job.
	# Only runs once per day to keep API costs low (~11 core API calls/run).
	local cache_dir="${HOME}/.aidevops/cache"
	local last_contrib_file="${cache_dir}/contributions-last-update"
	local today
	today=$(date -u +"%Y-%m-%d")
	local last_contrib_date=""
	if [[ -f "$last_contrib_file" ]]; then
		last_contrib_date=$(cat "$last_contrib_file" 2>/dev/null || true)
	fi
	if [[ "$last_contrib_date" != "$today" ]] && grep -q '<!-- CONTRIBUTIONS-START -->' "$readme_path" 2>/dev/null; then
		echo "Daily contributions refresh triggered..."
		if [[ "$dry_run" == true ]]; then
			cmd_update_contributions "--dry-run" || echo "Warning: contributions update failed — continuing with stats" >&2
		else
			cmd_update_contributions || echo "Warning: contributions update failed — continuing with stats" >&2
		fi
		if [[ "$dry_run" != true ]]; then
			git -C "$profile_repo" pull --rebase --quiet 2>/dev/null || true
		fi
	fi

	# Ensure markers exist — inject or regenerate if missing
	_update_inject_markers_if_needed "$profile_repo" "$readme_path"

	# Replace content between markers
	local tmp_file
	tmp_file=$(mktemp)
	NEW_STATS="$new_stats" awk '
		/<!-- STATS-START -->/ {
			print "<!-- STATS-START -->"
			skip = 1
			next
		}
		/<!-- STATS-END -->/ {
			skip = 0
			printf "%s\n", ENVIRON["NEW_STATS"]
			print "<!-- STATS-END -->"
			next
		}
		!skip { print }
	' "$readme_path" >"$tmp_file"
	local gh_user
	gh_user=$(_resolve_profile_user "$profile_repo")
	_ensure_commit_history_chart "$tmp_file" "$gh_user"

	# Check if content changed, ignoring UPDATED marker block
	local old_normalized new_normalized
	old_normalized=$(_normalize_readme_for_compare "$readme_path")
	new_normalized=$(_normalize_readme_for_compare "$tmp_file")
	if [[ "$old_normalized" == "$new_normalized" ]]; then
		echo "No changes to profile content — skipping commit"
		rm -f "$tmp_file"
		return 0
	fi

	# Update timestamp
	_update_inject_timestamp "$tmp_file"

	if [[ "$dry_run" == true ]]; then
		echo "--- DRY RUN: would write to $readme_path ---"
		diff "$readme_path" "$tmp_file" || true
		rm -f "$tmp_file"
		return 0
	fi

	# Apply changes and push
	mv "$tmp_file" "$readme_path"
	echo "Profile README content changed — committing and pushing"
	_update_push_with_recovery "$profile_repo" "chore: update profile stats ($(date -u +%Y-%m-%d))" "$@"

	echo "Profile README updated and pushed"
	return 0
}

# --- Classify contribution marker topology ---
_contribution_marker_state() {
	local readme_path="$1"
	if [[ ! -r "$readme_path" ]]; then
		printf '%s\n' invalid
		return 0
	fi
	local start_exact end_exact start_any end_any
	start_exact=$(grep -cFx "$CONTRIBUTIONS_START_MARKER" "$readme_path" 2>/dev/null || true)
	end_exact=$(grep -cFx "$CONTRIBUTIONS_END_MARKER" "$readme_path" 2>/dev/null || true)
	start_any=$(grep -cF 'CONTRIBUTIONS-START' "$readme_path" 2>/dev/null || true)
	end_any=$(grep -cF 'CONTRIBUTIONS-END' "$readme_path" 2>/dev/null || true)

	if [[ "$start_exact" -eq 1 && "$end_exact" -eq 1 && "$start_any" -eq 1 && "$end_any" -eq 1 ]]; then
		local start_line end_line
		start_line=$(grep -nFx "$CONTRIBUTIONS_START_MARKER" "$readme_path" | cut -d: -f1)
		end_line=$(grep -nFx "$CONTRIBUTIONS_END_MARKER" "$readme_path" | cut -d: -f1)
		[[ "$start_line" -lt "$end_line" ]] && printf '%s\n' valid || printf '%s\n' invalid
		return 0
	fi
	if [[ "$start_any" -eq 0 && "$end_any" -eq 0 ]]; then
		printf '%s\n' absent
		return 0
	fi
	if [[ "$start_exact" -eq 1 && "$start_any" -eq 1 && "$end_exact" -eq 0 && "$end_any" -eq 1 ]] &&
		awk -v marker="$CONTRIBUTIONS_END_MARKER" '
			index($0, marker) > 1 && index($0, marker) + length(marker) - 1 == length($0) { found = 1 }
			END { exit(found ? 0 : 1) }
		' "$readme_path"; then
		printf '%s\n' legacy-joined-end
		return 0
	fi
	printf '%s\n' invalid
	return 0
}

# --- Normalize the legacy generated form with END joined to the last item ---
_normalize_legacy_contribution_end() {
	local readme_path="$1"
	local output_path="$2"
	awk -v marker="$CONTRIBUTIONS_END_MARKER" '
		{
			position = index($0, marker)
			if (position > 1 && position + length(marker) - 1 == length($0)) {
				print substr($0, 1, position - 1)
				print marker
				next
			}
			print
		}
	' "$readme_path" >"$output_path"
	return $?
}

# --- Migrate static Contributions section to auto-updated markers ---
# Usage: _update_contributions_migrate_markers <readme_path> <dry_run>
_update_contributions_migrate_markers() {
	local readme_path="$1"
	local dry_run="$2"
	local marker_state
	marker_state=$(_contribution_marker_state "$readme_path")

	case "$marker_state" in
	valid)
		return 0
		;;
	invalid)
		echo "Error: Contributions markers must be one standalone, ordered pair" >&2
		return 1
		;;
	legacy-joined-end)
		if [[ "$dry_run" == true ]]; then
			echo "Note: legacy joined Contributions marker would be normalized"
			return 1
		fi
		local normalize_tmp
		normalize_tmp=$(mktemp)
		if ! _normalize_legacy_contribution_end "$readme_path" "$normalize_tmp"; then
			rm -f "$normalize_tmp"
			return 1
		fi
		if [[ "$(_contribution_marker_state "$normalize_tmp")" != valid ]]; then
			rm -f "$normalize_tmp"
			return 1
		fi
		mv "$normalize_tmp" "$readme_path"
		return 0
		;;
	absent) ;;
	esac

	if [[ "$dry_run" == true ]]; then
		echo "Note: CONTRIBUTIONS markers not found — would migrate static section"
		return 1
	fi

	echo "Migrating static Contributions section to auto-updated markers..."
	local inject_tmp
	inject_tmp=$(mktemp)
	if ! awk -v start_marker="$CONTRIBUTIONS_START_MARKER" -v end_marker="$CONTRIBUTIONS_END_MARKER" '
		/^## Contributions/ { in_old_contrib = 1; next }
		in_old_contrib && /^## / {
			in_old_contrib = 0
			print start_marker
			print end_marker
			print ""
			print $0
			next
		}
		in_old_contrib { next }
		{ print }
	' "$readme_path" >"$inject_tmp"; then
		rm -f "$inject_tmp"
		return 1
	fi
	# If EOF reached while still in old section, append markers
	if ! grep -qxF "$CONTRIBUTIONS_START_MARKER" "$inject_tmp"; then
		{
			echo "$CONTRIBUTIONS_START_MARKER"
			echo "$CONTRIBUTIONS_END_MARKER"
		} >>"$inject_tmp"
	fi
	if [[ "$(_contribution_marker_state "$inject_tmp")" != valid ]]; then
		echo "Error: valid Contributions markers not found after migration" >&2
		rm -f "$inject_tmp"
		return 1
	fi
	mv "$inject_tmp" "$readme_path"
	return 0
}

# --- Record the daily contributions throttle after a complete refresh ---
_record_contributions_update() {
	local cache_dir="${HOME}/.aidevops/cache"
	if ! mkdir -p "$cache_dir"; then
		echo "Warning: could not create contributions throttle cache" >&2
		return 1
	fi
	if ! date -u +"%Y-%m-%d" >"${cache_dir}/contributions-last-update"; then
		echo "Warning: could not record contributions refresh timestamp" >&2
		return 1
	fi
	return 0
}

_contributions_pending_push_file() {
	printf '%s\n' "${HOME}/.aidevops/cache/contributions-pending-push"
	return 0
}

_record_pending_contributions_push() {
	local profile_repo="$1"
	local pending_file
	pending_file=$(_contributions_pending_push_file)
	mkdir -p "${pending_file%/*}" || return 1
	git -C "$profile_repo" rev-parse HEAD >"$pending_file"
	return $?
}

_clear_pending_contributions_push() {
	local pending_file
	pending_file=$(_contributions_pending_push_file)
	rm -f "$pending_file"
	return 0
}

# --- Resolve the profile repository's push branch ---
_profile_default_branch() {
	local profile_repo="$1"
	local default_branch=""
	default_branch=$(git -C "$profile_repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
	if [[ -z "$default_branch" ]]; then
		default_branch=$(git -C "$profile_repo" branch --show-current 2>/dev/null || true)
	fi
	printf '%s\n' "${default_branch:-main}"
	return 0
}

# --- Commit and push contributions update, recording daily throttle timestamp ---
# Usage: _update_contributions_push <profile_repo>
_update_contributions_push() {
	local profile_repo="$1"
	local readme_path="${profile_repo}/README.md"

	# Update timestamp
	_update_inject_timestamp "$readme_path"

	local commit_msg
	commit_msg="chore: update profile contributions ($(date -u +%Y-%m-%d))"
	git -C "$profile_repo" add README.md
	if ! git -C "$profile_repo" commit -m "$commit_msg" --no-verify -- README.md 2>/dev/null; then
		echo "Warning: contributions commit failed" >&2
		return 1
	fi
	_record_pending_contributions_push "$profile_repo" || return 1

	local default_branch
	default_branch=$(_profile_default_branch "$profile_repo")
	if ! git -C "$profile_repo" push origin "$default_branch" 2>/dev/null; then
		echo "Warning: push failed — contributions committed locally" >&2
		return 1
	fi
	_clear_pending_contributions_push
	_record_contributions_update || return 1

	echo "Profile contributions updated and pushed"
	return 0
}

# --- Verify a profile write cannot publish unrelated local work ---
_ensure_profile_write_ready() {
	local profile_repo="$1"
	local readme_status=""
	if ! readme_status=$(git -C "$profile_repo" status --porcelain -- README.md 2>/dev/null); then
		echo "Warning: could not verify local profile README state" >&2
		return 1
	fi
	if [[ -n "$readme_status" ]]; then
		echo "Warning: local profile README has uncommitted changes; refusing automated commit" >&2
		return 1
	fi
	if ! git -C "$profile_repo" diff --cached --quiet; then
		echo "Warning: profile repository has unrelated staged changes" >&2
		return 1
	fi

	local default_branch ahead_count pending_file pending_sha head_sha
	default_branch=$(_profile_default_branch "$profile_repo")
	if ! ahead_count=$(git -C "$profile_repo" rev-list --count "origin/${default_branch}..HEAD" 2>/dev/null); then
		echo "Warning: could not verify whether profile contributions were pushed" >&2
		return 1
	fi
	if [[ "$ahead_count" -gt 0 ]] 2>/dev/null; then
		pending_file=$(_contributions_pending_push_file)
		if [[ ! -f "$pending_file" ]]; then
			echo "Warning: local profile branch has unrelated unpushed commits" >&2
			return 1
		fi
		pending_sha=$(<"$pending_file")
		head_sha=$(git -C "$profile_repo" rev-parse HEAD 2>/dev/null || true)
		if [[ -z "$pending_sha" || "$pending_sha" != "$head_sha" ]]; then
			echo "Warning: pending contributions marker does not match local profile HEAD" >&2
			return 1
		fi
		if ! git -C "$profile_repo" push origin "$default_branch" 2>/dev/null; then
			echo "Warning: pending profile contributions push failed" >&2
			return 1
		fi
	fi
	_clear_pending_contributions_push
	return 0
}

# --- Complete a local no-op without suppressing pending push retries ---
_finalize_unchanged_contributions() {
	local profile_repo="$1"
	_ensure_profile_write_ready "$profile_repo" || return 1
	_record_contributions_update || return 1
	return 0
}

# --- Render a validated contributions block into a candidate README ---
_render_contributions_candidate() {
	local readme_path="$1"
	local new_contribs="$2"
	local contribs_block=""
	if [[ -n "$new_contribs" ]]; then
		contribs_block="## Contributions"$'\n'$'\n'"${new_contribs}"$'\n'
	fi
	if ! CONTRIBS_BLOCK="$contribs_block" awk \
		-v start_marker="$CONTRIBUTIONS_START_MARKER" \
		-v end_marker="$CONTRIBUTIONS_END_MARKER" '
		$0 == start_marker {
			print
			skip = 1
			next
		}
		$0 == end_marker {
			skip = 0
			block = ENVIRON["CONTRIBS_BLOCK"]
			if (block != "") {
				printf "%s", block
			}
			print
			next
		}
		!skip { print }
	' "$readme_path"; then
		return 1
	fi
	return 0
}

# --- Update contributions section between markers ---
# Can be called standalone or from cmd_update with daily throttle.
# Uses _generate_contributions() to fetch fork parent URLs + repos.json entries.
cmd_update_contributions() {
	local dry_run=false
	if [[ "${1:-}" == "--dry-run" ]]; then
		dry_run=true
	fi

	# Resolve profile repo and user
	local profile_repo
	profile_repo=$(_resolve_profile_repo) || return 1
	local readme_path="${profile_repo}/README.md"

	if [[ ! -f "$readme_path" ]]; then
		echo "Error: README.md not found at $readme_path" >&2
		return 1
	fi

	# Resolve GitHub username
	local gh_user
	gh_user=$(_resolve_profile_user "$profile_repo")
	if [[ -z "$gh_user" ]]; then
		echo "Error: could not resolve GitHub username for profile repo" >&2
		return 1
	fi

	# Generate new contributions content
	local new_contribs
	if ! new_contribs=$(_generate_contributions "$gh_user"); then
		echo "Warning: contributions refresh aborted; existing Contributions block was preserved" >&2
		return 1
	fi
	if [[ "$dry_run" != true ]]; then
		_ensure_profile_write_ready "$profile_repo" || return 1
	fi

	# Build every migration and render in temporary files. README.md is replaced
	# only after all remote reads, marker transforms, and rendering succeed.
	local migration_source
	migration_source=$(mktemp)
	if ! cp "$readme_path" "$migration_source"; then
		rm -f "$migration_source"
		return 1
	fi
	if ! _update_contributions_migrate_markers "$migration_source" "$dry_run"; then
		rm -f "$migration_source"
		if [[ "$dry_run" == true ]] && [[ "$(_contribution_marker_state "$readme_path")" == absent ]]; then
			return 0
		fi
		return 1
	fi

	# Replace content between markers
	local tmp_file
	tmp_file=$(mktemp)
	if ! _render_contributions_candidate "$migration_source" "$new_contribs" >"$tmp_file"; then
		rm -f "$migration_source" "$tmp_file"
		return 1
	fi
	rm -f "$migration_source"

	# Check if content actually changed
	if diff -q "$readme_path" "$tmp_file" >/dev/null 2>&1; then
		echo "Contributions unchanged — skipping"
		rm -f "$tmp_file"
		if [[ "$dry_run" != true ]]; then
			_finalize_unchanged_contributions "$profile_repo" || return 1
		fi
		return 0
	fi

	if [[ "$dry_run" == true ]]; then
		echo "--- DRY RUN: contributions changes ---"
		diff "$readme_path" "$tmp_file" || true
		rm -f "$tmp_file"
		return 0
	fi

	# Apply changes and push
	if ! mv "$tmp_file" "$readme_path"; then
		rm -f "$tmp_file"
		return 1
	fi
	_update_contributions_push "$profile_repo" || return 1
	return 0
}

# --- Main dispatch ---
case "${1:-help}" in
init) cmd_init ;;
generate) cmd_generate ;;
update)
	shift
	cmd_update "$@"
	;;
update-contributions)
	shift
	cmd_update_contributions "$@"
	;;
help | *)
	echo "Usage: profile-readme-helper.sh {init|update|update-contributions|generate|help}"
	echo ""
	echo "Commands:"
	echo "  init                          Create profile repo, seed README, register in repos.json"
	echo "  update [--dry-run]            Update profile README with live stats and push"
	echo "  update-contributions [--dry-run]  Refresh contributions list from forks + repos.json"
	echo "  generate                      Print generated stats section to stdout"
	echo "  help                          Show this help"
	echo ""
	echo "The 'update' command automatically refreshes contributions once per day."
	echo "Use 'update-contributions' to force an immediate refresh."
	;;
esac
