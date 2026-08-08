#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# init-routines-helper.sh — scaffold a private routines repo and register it
#
# Usage:
#   init-routines-helper.sh [--org <name>] [--local] [--dry-run] [--help]
#
# Options:
#   --org <name>   Create per-org variant: <org>/aidevops-routines
#   --local        Create local-only repo (no remote, local_only: true)
#   --dry-run      Print what would be done without making changes
#   --help         Show this help message
#
# Without flags: creates personal <username>/aidevops-routines (always private)

set -Eeuo pipefail
IFS=$'\n\t'

# Colors (guarded — GH#18702)
# When this helper is sourced from setup.sh (via _routines.sh), the parent
# shell has already sourced shared-constants.sh which declares these as
# readonly. Unguarded assignment would fail under `set -Eeuo pipefail` and
# kill the whole setup.sh run. Use the `${VAR+x}` guard which skips the
# assignment when the variable is already set (readonly or not).
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

REPOS_JSON="${HOME}/.config/aidevops/repos.json"
GIT_PARENT="${HOME}/Git"
DRY_RUN=false
ROUTINES_SCAFFOLD_COMMIT_MESSAGE="chore: scaffold aidevops-routines repo"
# SCRIPT_DIR: resolve from BASH_SOURCE when available, fall back to deployed path
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" != "$0" || -f "${BASH_SOURCE[0]}" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
	SCRIPT_DIR="${HOME}/.aidevops/agents/scripts"
fi

# ---------------------------------------------------------------------------
# _write_todo_md <path>
# Creates TODO.md with Routines section header, format reference, and
# seeded core routine entries from core-routines.sh.
# ---------------------------------------------------------------------------
_write_todo_md() {
	local repo_path="$1"

	# Header
	cat >"${repo_path}/TODO.md" <<'TODOEOF'
# Routines

Recurring operational jobs. Format reference: .agents/reference/routines.md

Fields:
  repeat: -- schedule: daily(@HH:MM), weekly(day@HH:MM), monthly(N@HH:MM), cron(expr)
  run:    -- deterministic script relative to ~/.aidevops/agents/
  agent:  -- LLM agent dispatched via headless-runtime-helper.sh
  timezone: -- optional per-routine IANA timezone override
  [x] enabled, [ ] disabled/paused

## Core Routines (framework-managed)

<!-- These routines are managed by aidevops setup. Enabled state, repeat:
     expressions, and scripts are version controlled here. Pulse evaluates
     most entries; routines documented as persistent may use a dedicated
     launchd or systemd unit. Edit only the enabled/disabled state here. -->

TODOEOF

	# Seed core routine entries if core-routines.sh is available
	if [[ -f "${SCRIPT_DIR}/routines/core-routines.sh" ]]; then
		# shellcheck disable=SC1091  # sourced file path is dynamic but verified above
		source "${SCRIPT_DIR}/routines/core-routines.sh"
		local rid enabled title schedule estimate script rtype timezone
		local timezone_field=""
		while IFS='|' read -r rid enabled title schedule estimate script rtype timezone; do
			[[ -z "$rid" ]] && continue
			timezone_field="${timezone:+ timezone:${timezone}}"
			printf '%s\n' "- [${enabled}] ${rid} ${title} ${schedule}${timezone_field} ${estimate} run:${script}" >>"${repo_path}/TODO.md"
		done < <(get_core_routine_entries)
	fi

	# User routines section + tasks
	cat >>"${repo_path}/TODO.md" <<'TODOEOF'

## User Routines

<!-- Add your own routines below. Use r001-r899 for user routines.
     Core routines use r901+ to avoid ID collisions. Example:
- [x] r001 Weekly SEO rankings export repeat:weekly(mon@09:00) ~30m run:custom/scripts/seo-export.sh
- [ ] r002 Monthly content calendar review repeat:monthly(1@09:00) ~15m agent:Content
-->

## Tasks

<!-- Non-recurring tasks go here -->
TODOEOF
	return 0
}

# ---------------------------------------------------------------------------
# _seed_routine_descriptions <repo_path>
# Writes core routine description .md files into routines/core/.
# Also creates routines/custom/ for user overrides.
# ---------------------------------------------------------------------------
_seed_routine_descriptions() {
	local repo_path="$1"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would seed routine descriptions into: ${repo_path}/routines/"
		return 0
	fi

	mkdir -p "${repo_path}/routines/core"
	mkdir -p "${repo_path}/routines/custom"

	# Custom dir README
	if [[ ! -f "${repo_path}/routines/custom/README.md" ]]; then
		cat >"${repo_path}/routines/custom/README.md" <<'CUSTOMEOF'
# Custom Routine Descriptions

Place your own routine description files here as `<routine-id>.md` (e.g., `r001.md`).

Custom descriptions override core descriptions when both exist for the same ID.
Use the template at `~/.aidevops/agents/templates/routine-description-template.md`
as a starting point, or copy and modify a core description from `../core/`.

These files survive framework updates — core descriptions may be refreshed,
but custom descriptions are never overwritten.
CUSTOMEOF
	fi

	# Write core descriptions from core-routines.sh describe_* functions
	if [[ ! -f "${SCRIPT_DIR}/routines/core-routines.sh" ]]; then
		print_warning "core-routines.sh not found — skipping description seeding"
		return 0
	fi

	# shellcheck disable=SC1091  # sourced file path is dynamic but verified above
	source "${SCRIPT_DIR}/routines/core-routines.sh"

	# Detect OS for platform-specific descriptions
	local detected_os
	detected_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
	# Normalise: Darwin → darwin, Linux → linux
	case "$detected_os" in
	darwin) detected_os="darwin" ;;
	*) detected_os="linux" ;;
	esac

	local rid
	local gen_header
	gen_header="<!-- GENERATED FILE — DO NOT EDIT IN THIS REPO -->
<!-- Source: marcusquinn/aidevops:.agents/scripts/routines/core-routines.sh -->
<!-- Overwritten by: aidevops update / init-routines-helper.sh -->
<!-- To fix: edit describe_rNNN() in core-routines.sh, not this file -->

"
	while IFS='|' read -r rid _ _ _ _ _ _ _; do
		[[ -z "$rid" ]] && continue
		local describe_fn="describe_${rid}"
		if declare -f "$describe_fn" &>/dev/null; then
			{
				printf '%s' "$gen_header"
				"$describe_fn" "$detected_os"
			} >"${repo_path}/routines/core/${rid}.md"
		fi
	done < <(get_core_routine_entries)

	print_success "Seeded routine descriptions into: ${repo_path}/routines/"
	return 0
}

# ---------------------------------------------------------------------------
# _write_issue_template <path>
# Creates .github/ISSUE_TEMPLATE/routine.md
# ---------------------------------------------------------------------------
_write_issue_template() {
	local repo_path="$1"
	cat >"${repo_path}/.github/ISSUE_TEMPLATE/routine.md" <<'TEMPLATEEOF'
---
name: Routine tracking
about: Track a recurring operational routine (auto-created by routine-log-helper.sh create-issue)
title: "r000: <routine name>"
labels: routines
assignees: ''
---

## r000: <routine name>

| Field | Value |
|-------|-------|
| Schedule | repeat:weekly(mon@09:00) |
| Type | script |
| Status | active |
| Last run | — |
| Last result | — |
| Next run | pending first run |
| Streak | — |
| Total cost | $0.00 |

### Latest Period (— — —)
0/0 runs succeeded. Total cost: $0.00. Avg duration: 0s.

**Detailed logs**: `~/.aidevops/.agent-workspace/cron/r000/`

---

> This issue is auto-managed by `routine-log-helper.sh`. The body is updated
> after each run with live metrics. Do not edit the body manually — changes
> will be overwritten on the next run.
>
> To view logs: `routine-log-helper.sh status`
> To update manually: `routine-log-helper.sh update r000 --status success --duration 30`
TEMPLATEEOF
	return 0
}

# ---------------------------------------------------------------------------
# _write_agents_md <path>
# Creates AGENTS.md with worker routing protection.
# Prevents workers from editing generated files in the wrong repo.
# ---------------------------------------------------------------------------
_write_agents_md() {
	local repo_path="$1"
	cat >"${repo_path}/AGENTS.md" <<'AGENTSEOF'
# aidevops-routines — Worker Instructions

## What this repo is

This repo contains routine **definitions** (TODO.md) and **tracking issues**
(GitHub issues updated by `routine-log-helper.sh`). It is a downstream
consumer of the aidevops framework, not the source of truth for routine
code or descriptions.

## Generated files — DO NOT EDIT HERE

Files in `routines/core/` are **generated** by the aidevops framework
(`~/.aidevops/agents/scripts/routines/core-routines.sh`). They are
overwritten on every `aidevops update` or `init-routines-helper.sh` run.

**If you find an error in a core routine description:**
1. Do NOT edit `routines/core/*.md` in this repo
2. Fix the source: `describe_rNNN()` function in
   `marcusquinn/aidevops:.agents/scripts/routines/core-routines.sh`
3. The fix will propagate here on the next `aidevops update`

**If you find a bug in `routine-log-helper.sh` or other framework scripts:**
1. These scripts live in `marcusquinn/aidevops:.agents/scripts/`
2. Do NOT copy them into this repo — fix them at the source

## What CAN be edited here

- `TODO.md` — routine definitions (enable/disable, add user routines r001-r899)
- `routines/custom/*.md` — user-defined routine descriptions
- `README.md` — repo documentation
- `.github/ISSUE_TEMPLATE/` — issue templates

## Issue routing

- Issues labelled `routine-tracking` (r901-r912) are **execution tracking
  issues** — their bodies are auto-updated by `routine-log-helper.sh` with
  run metrics. Do not edit issue bodies manually.
- Issues about routine **behaviour or bugs** should be filed on the main
  `marcusquinn/aidevops` repo, not here.
- Issues about routine **scheduling or enablement** belong here (edit TODO.md).

## User comments on tracking issues

Users may comment on tracking issues with questions or change requests.
These comments are legitimate and should be responded to — they serve as
an audit trail of routine management decisions.

**If dispatched to respond to a comment on a `routine-tracking` issue:**

1. Read the user's comment carefully
2. If it's a **question** (e.g., "why did this fail?"): answer using the
   routine description in the issue body, logs at
   `~/.aidevops/.agent-workspace/cron/<id>/`, and `routine-log-helper.sh status`
3. If it's a **change request** (e.g., "change schedule to every 5 minutes"):
   - Apply the change to `TODO.md` in this repo (edit the `repeat:` field)
   - Comment back confirming the change with before/after
   - Do NOT create a PR for TODO.md changes — they go direct to main
4. If it's a **bug report** about the routine itself: create an issue on the
   main `marcusquinn/aidevops` repo (the routine code lives there)
5. **NEVER** try to "implement" or "solve" a tracking issue — they are
   dashboards, not tasks
AGENTSEOF
	return 0
}

# ---------------------------------------------------------------------------
# _write_codeowners <path>
# Creates CODEOWNERS to flag PRs touching generated files.
# ---------------------------------------------------------------------------
_write_codeowners() {
	local repo_path="$1"
	mkdir -p "${repo_path}/.github"
	cat >"${repo_path}/.github/CODEOWNERS" <<'COEOF'
# Generated files — changes here will be overwritten by aidevops update.
# PRs touching these paths require maintainer review to confirm the fix
# should be in the source repo (marcusquinn/aidevops) instead.
/routines/core/ @marcusquinn
COEOF
	return 0
}

# ---------------------------------------------------------------------------
# _write_readme <path>
# Creates README.md with repo overview and structure documentation.
# ---------------------------------------------------------------------------
_write_readme() {
	local repo_path="$1"
	cat >"${repo_path}/README.md" <<'READMEEOF'
# aidevops-routines

Recurring operational routines for the [aidevops](https://aidevops.sh) framework.

## Structure

```
TODO.md                 # Routine definitions (schedule, script, enabled state)
routines/
├── core/               # Generated by aidevops framework (DO NOT EDIT — see AGENTS.md)
│   ├── r901.md         # Supervisor pulse
│   ├── r902.md         # Auto-update
│   └── ...             # 12 core routines total
└── custom/             # User-defined routine descriptions (survives updates)
    └── README.md
```

## Core vs custom routines

| Range | Owner | Editable here? |
|-------|-------|----------------|
| r901-r999 | Framework (aidevops) | No — generated, fix at source |
| r001-r899 | User | Yes — add to TODO.md + routines/custom/ |

## Tracking issues

Each routine has a GitHub issue auto-updated after every run with metrics
(last run, streak, cost). Notable events are posted as comments.

```bash
routine-log-helper.sh status    # View all routine metrics
```

## Adding a custom routine

1. Add to `TODO.md` under `## User Routines`:
   ```
   - [x] r001 My routine repeat:daily(@09:00) ~5m run:custom/scripts/my-routine.sh
   ```
2. Create `routines/custom/r001.md` with a description
3. Create a tracking issue: `routine-log-helper.sh create-issue r001 --repo <slug> --title "r001: My routine"`
READMEEOF
	return 0
}

# ---------------------------------------------------------------------------
# scaffold_repo <path>
# Creates the standard routines repo structure at the given path.
# ---------------------------------------------------------------------------
scaffold_repo() {
	local repo_path="$1"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would scaffold repo at: $repo_path"
		return 0
	fi

	mkdir -p "${repo_path}/routines"
	mkdir -p "${repo_path}/.github/ISSUE_TEMPLATE"

	_write_todo_md "$repo_path"
	_seed_routine_descriptions "$repo_path"
	_write_agents_md "$repo_path"
	_write_codeowners "$repo_path"
	_write_readme "$repo_path"

	# .gitignore
	cat >"${repo_path}/.gitignore" <<'GITIGNOREEOF'
# OS
.DS_Store
Thumbs.db

# Editor
.vscode/
.idea/
*.swp
*.swo

# Runtime
*.log
tmp/
GITIGNOREEOF

	_write_issue_template "$repo_path"

	print_success "Scaffolded repo at: $repo_path"
	return 0
}

# ---------------------------------------------------------------------------
# register_repo <path> <slug> [local_only]
# Appends the repo to repos.json initialized_repos array.
# ---------------------------------------------------------------------------
register_repo() {
	local repo_path="$1"
	local slug="$2"
	local local_only="${3:-false}"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would register in repos.json: path=$repo_path slug=$slug local_only=$local_only"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_warning "jq not found — skipping repos.json registration. Add manually:"
		echo "  path: $repo_path"
		echo "  slug: $slug"
		return 0
	fi

	# Ensure repos.json exists with correct structure
	if [[ ! -f "$REPOS_JSON" ]]; then
		mkdir -p "$(dirname "$REPOS_JSON")"
		echo '{"initialized_repos": [], "git_parent_dirs": ["~/Git"]}' >"$REPOS_JSON"
	fi

	# Check if already registered
	if jq -e --arg path "$repo_path" '.initialized_repos[] | select(.path == $path)' "$REPOS_JSON" &>/dev/null; then
		print_info "Already registered in repos.json: $repo_path"
		return 0
	fi

	local tmp_json
	tmp_json=$(mktemp)

	local maintainer=""
	if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
		maintainer=$(gh api user --jq '.login' 2>/dev/null || echo "")
	fi

	local jq_filter
	# shellcheck disable=SC2016  # jq uses $path/$slug/$maintainer as jq vars, not shell vars
	if [[ "$local_only" == "true" ]]; then
		jq_filter='.initialized_repos += [{
		  "path": $path,
		  "slug": $slug,
		  "pulse": true,
		  "priority": "tooling",
		  "local_only": true,
		  "maintainer": $maintainer,
		  "initialized": (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
		}]'
	else
		jq_filter='.initialized_repos += [{
		  "path": $path,
		  "slug": $slug,
		  "pulse": true,
		  "priority": "tooling",
		  "maintainer": $maintainer,
		  "initialized": (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
		}]'
	fi

	jq --arg path "$repo_path" \
		--arg slug "$slug" \
		--arg maintainer "$maintainer" \
		"$jq_filter" "$REPOS_JSON" >"$tmp_json"

	if jq empty "$tmp_json" 2>/dev/null; then
		mv "$tmp_json" "$REPOS_JSON"
		print_success "Registered in repos.json: $slug"
	else
		print_error "repos.json write produced invalid JSON — aborting (GH#16746)"
		rm -f "$tmp_json"
		return 1
	fi

	return 0
}

# ---------------------------------------------------------------------------
# _routines_publish_path_allowed <path>
# Restricts isolated publication to files owned by routines scaffolding.
# ---------------------------------------------------------------------------
_routines_publish_path_allowed() {
	local path="$1"
	case "$path" in
	TODO.md | AGENTS.md | README.md | .gitignore | .github/CODEOWNERS | .github/ISSUE_TEMPLATE/routine.md | routines/custom/README.md | routines/core/*.md)
		[[ "$path" != *'..'* && "$path" != *'//'* && "$path" != */ ]]
		return $?
		;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# _routines_remote_default_branch <path>
# Resolves origin's default branch without updating canonical refs.
# ---------------------------------------------------------------------------
_routines_remote_default_branch() {
	local repo_path="$1"
	local remote_head=""
	local branch=""
	remote_head=$(git -C "$repo_path" ls-remote --symref origin HEAD 2>/dev/null) || return 1
	branch=$(printf '%s\n' "$remote_head" | sed -n 's@^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$@\1@p')
	[[ -n "$branch" && "$branch" != *$'\n'* ]] || return 1
	printf '%s\n' "$branch"
	return 0
}

# ---------------------------------------------------------------------------
# _routines_publish_changed_paths_allowed <path>
# Fails closed when staging contains a path not owned by scaffold_repo.
# ---------------------------------------------------------------------------
_routines_publish_changed_paths_allowed() {
	local repo_path="$1"
	local path=""
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		if ! _routines_publish_path_allowed "$path"; then
			print_warning "Routines publication refused unexpected path: $path"
			return 1
		fi
	done < <(git -C "$repo_path" diff --cached --name-only)
	return 0
}

# ---------------------------------------------------------------------------
# _publish_routines_scaffold <canonical-path>
# Clones, scaffolds, validates, commits, and lease-pushes from disposable state.
# The pre-existing canonical checkout is queried only with read-only commands.
# ---------------------------------------------------------------------------
_publish_routines_scaffold() {
	local repo_path="$1"
	local origin_url=""
	local branch=""
	local attempt=0
	local max_retries="${AIDEVOPS_ROUTINES_PUBLISH_MAX_RETRIES:-3}"
	origin_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || return 1
	branch=$(_routines_remote_default_branch "$repo_path") || {
		print_warning "Unable to determine routines remote default branch"
		return 1
	}

	while [[ "$attempt" -lt "$max_retries" ]]; do
		attempt=$((attempt + 1))
		local temp_dir=""
		local staging_repo=""
		local parent_sha=""
		local changed_paths=""
		temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/routines-publisher.XXXXXX") || return 1
		staging_repo="${temp_dir}/repo"
		if ! git -C "$temp_dir" clone -q --single-branch --branch "$branch" "$origin_url" "$staging_repo"; then
			rm -rf "$temp_dir"
			return 1
		fi
		parent_sha=$(git -C "$staging_repo" rev-parse HEAD) || {
			rm -rf "$temp_dir"
			return 1
		}
		scaffold_repo "$staging_repo"
		git -C "$staging_repo" add -A || {
			rm -rf "$temp_dir"
			return 1
		}
		if git -C "$staging_repo" diff --cached --quiet; then
			rm -rf "$temp_dir"
			return 0
		fi
		_routines_publish_changed_paths_allowed "$staging_repo" || {
			rm -rf "$temp_dir"
			return 1
		}
		changed_paths=$(git -C "$staging_repo" diff --cached --name-only) || {
			rm -rf "$temp_dir"
			return 1
		}
		if [[ -n "${AIDEVOPS_ROUTINES_PUBLISH_VALIDATOR:-}" ]] && ! "${AIDEVOPS_ROUTINES_PUBLISH_VALIDATOR}" "$staging_repo" "$parent_sha"; then
			print_warning "Routines publication validation failed; canonical checkout and remote are unchanged"
			rm -rf "$temp_dir"
			return 1
		fi
		git -C "$staging_repo" -c user.name="aidevops" -c user.email="aidevops@example.invalid" -c commit.gpgsign=false \
			commit -q -m "$ROUTINES_SCAFFOLD_COMMIT_MESSAGE" || {
			rm -rf "$temp_dir"
			return 1
		}
		if [[ -n "${AIDEVOPS_ROUTINES_BEFORE_PUSH_HOOK:-}" ]]; then
			"${AIDEVOPS_ROUTINES_BEFORE_PUSH_HOOK}" "$origin_url" "$branch" "$attempt" || {
				rm -rf "$temp_dir"
				return 1
			}
		fi
		if git -C "$staging_repo" push -q --force-with-lease="refs/heads/${branch}:${parent_sha}" \
			origin "HEAD:refs/heads/${branch}"; then
			rm -rf "$temp_dir"
			print_success "Published routines scaffold from isolated state"
			return 0
		fi
		local latest_sha=""
		local changed_path=""
		if ! git -C "$staging_repo" fetch -q origin "$branch" ||
			! latest_sha=$(git -C "$staging_repo" rev-parse FETCH_HEAD); then
			rm -rf "$temp_dir"
			return 1
		fi
		while IFS= read -r changed_path; do
			[[ -n "$changed_path" ]] || continue
			if ! git -C "$staging_repo" diff --quiet "$parent_sha" "$latest_sha" -- "$changed_path"; then
				rm -rf "$temp_dir"
				print_warning "Routines publication conflict on generated path: $changed_path"
				return 2
			fi
		done <<<"$changed_paths"
		rm -rf "$temp_dir"
	done

	print_warning "Routines publication encountered concurrent remote updates; canonical checkout is unchanged"
	return 2
}

# ---------------------------------------------------------------------------
# _commit_and_push <path>
# Initializes a newly cloned checkout. Existing mirrors use isolated publishing.
# ---------------------------------------------------------------------------
_commit_and_push() {
	local repo_path="$1"
	git -C "$repo_path" add -A || return 1
	if git -C "$repo_path" diff --cached --quiet; then
		return 0
	fi
	git -C "$repo_path" commit -m "$ROUTINES_SCAFFOLD_COMMIT_MESSAGE" || return 1
	git -C "$repo_path" push origin HEAD || return 1
	return 0
}

# ---------------------------------------------------------------------------
# _check_gh_auth
# Returns 0 if gh CLI is available and authenticated, 1 otherwise.
# ---------------------------------------------------------------------------
_check_gh_auth() {
	if ! command -v gh &>/dev/null; then
		print_error "gh CLI not found. Install from https://cli.github.com/"
		return 1
	fi
	if ! gh auth status &>/dev/null 2>&1; then
		print_error "Not authenticated with gh. Run: gh auth login"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _ensure_gh_repo <slug> <description>
# Creates the GitHub repo if it doesn't exist. Always private.
# ---------------------------------------------------------------------------
_ensure_gh_repo() {
	local slug="$1"
	local description="$2"
	if gh repo view "$slug" &>/dev/null 2>&1; then
		print_info "Repo already exists on GitHub: $slug"
		return 0
	fi
	gh repo create "$slug" --private --description "$description" 2>&1
	print_success "Created GitHub repo: $slug"
	return 0
}

# ---------------------------------------------------------------------------
# _ensure_cloned <slug> <path>
# Clones the repo if not already present locally.
# ---------------------------------------------------------------------------
_ensure_cloned() {
	local slug="$1"
	local repo_path="$2"
	if [[ -d "$repo_path/.git" ]]; then
		print_info "Repo already cloned at: $repo_path"
		return 0
	fi
	mkdir -p "$GIT_PARENT"
	gh repo clone "$slug" "$repo_path" 2>&1
	print_success "Cloned to: $repo_path"
	return 0
}

# ---------------------------------------------------------------------------
# _detect_timezone
# Outputs the local timezone name (e.g., "Europe/London", "America/New_York").
# Falls back to UTC offset if timezone name unavailable.
# ---------------------------------------------------------------------------
_detect_timezone() {
	# macOS: read from systemsetup or /etc/localtime symlink
	if [[ -L /etc/localtime ]]; then
		local tz_link
		tz_link=$(readlink /etc/localtime 2>/dev/null || echo "")
		if [[ "$tz_link" == */zoneinfo/* ]]; then
			echo "${tz_link##*/zoneinfo/}"
			return 0
		fi
	fi
	# Linux: check timedatectl or TZ env
	if [[ -n "${TZ:-}" ]]; then
		echo "$TZ"
		return 0
	fi
	if command -v timedatectl &>/dev/null; then
		local tz
		tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
		if [[ -n "$tz" ]]; then
			echo "$tz"
			return 0
		fi
	fi
	# Fallback: UTC offset
	date +%Z
	return 0
}

# ---------------------------------------------------------------------------
# _humanise_schedule <repeat_expr> <timezone>
# Converts repeat:cron(...) or repeat:daily(...) to plain English with timezone.
# ---------------------------------------------------------------------------
_humanise_schedule() {
	local expr="$1"
	local tz="$2"

	case "$expr" in
	repeat:cron\(\*/1\ \*\ \*\ \*\ \*\))
		echo "Every minute (${tz})"
		;;
	repeat:cron\(\*/2\ \*\ \*\ \*\ \*\))
		echo "Every 2 minutes (${tz})"
		;;
	repeat:cron\(\*/5\ \*\ \*\ \*\ \*\))
		echo "Every 5 minutes (${tz})"
		;;
	repeat:cron\(\*/10\ \*\ \*\ \*\ \*\))
		echo "Every 10 minutes (${tz})"
		;;
	repeat:cron\(\*/30\ \*\ \*\ \*\ \*\))
		echo "Every 30 minutes (${tz})"
		;;
	repeat:cron\(0\ \*\ \*\ \*\ \*\))
		echo "Every hour, on the hour (${tz})"
		;;
	repeat:cron\(0\ \*/6\ \*\ \*\ \*\))
		echo "Every 6 hours (00:00, 06:00, 12:00, 18:00 ${tz})"
		;;
	repeat:daily\(@*\))
		local time_part
		time_part=$(echo "$expr" | sed 's/repeat:daily(@\(.*\))/\1/')
		echo "Daily at ${time_part} (${tz})"
		;;
	repeat:persistent)
		echo "Always running (persistent service)"
		;;
	*)
		# Return the raw expression with timezone for anything we don't recognise
		echo "${expr} (${tz})"
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# _store_routine_description <rid> <title> <schedule> <script> <type>
# Stores description and management text in the routine state file so that
# _build_issue_body includes them in the issue body (not a separate comment).
# ---------------------------------------------------------------------------
_store_routine_description() {
	local rid="$1"
	local title="$2"
	local schedule="$3"
	local script="$4"
	local rtype="$5"

	local state_dir="${HOME}/.aidevops/.agent-workspace/cron/${rid}"
	local state_file="${state_dir}/routine-state.json"
	mkdir -p "$state_dir"

	# Extract "What it does" from the describe function
	local description_body=""
	local describe_fn="describe_${rid}"
	if declare -f "$describe_fn" &>/dev/null; then
		local detected_os
		detected_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
		case "$detected_os" in
		darwin) detected_os="darwin" ;;
		*) detected_os="linux" ;;
		esac
		local full_desc
		full_desc=$("$describe_fn" "$detected_os")
		description_body=$(echo "$full_desc" | sed -n '/^## What it does$/,/^## /{
			/^## What it does$/d
			/^## /d
			p
		}')
	fi

	# Build management instructions
	local management
	management="### How to manage this routine

#### Via chat (interactive session)

| Action | Command |
|--------|---------|
| Pause this routine | \`/routine\` then select ${rid} and disable |
| Resume this routine | \`/routine\` then select ${rid} and enable |
| Change schedule | \`/routine\` then select ${rid} and edit schedule |
| View recent runs | Ask: \"show me the last 5 runs of ${rid}\" |
| View logs | Ask: \"show me the ${rid} logs\" |

#### Via command line

| Action | Command |
|--------|---------|
| Check status | \`routine-log-helper.sh status\` |
| View logs | \`cat ~/.aidevops/.agent-workspace/cron/${rid}/runs.jsonl | tail -5\` |
| Pause (edit TODO.md) | Change \`- [x] ${rid}\` to \`- [ ] ${rid}\` in the routines repo TODO.md |
| Resume (edit TODO.md) | Change \`- [ ] ${rid}\` to \`- [x] ${rid}\` in the routines repo TODO.md |
| Force a run now | \`~/.aidevops/agents/${script}\` |

> **Note:** This is a tracking issue. Its body is auto-updated with execution metrics by \`routine-log-helper.sh\`. Use the comments below for change requests or feature ideas."

	# Write authoritative routine metadata to state without touching execution
	# metrics. Existing state is retained so refreshes cannot synthesize runs or
	# reset streaks, duration, cost, or history.
	if [[ -f "$state_file" ]]; then
		local tmp
		tmp=$(mktemp)
		jq --arg t "$title" --arg s "$schedule" --arg rt "$rtype" \
			--arg d "$description_body" --arg m "$management" \
			'.title = $t | .schedule = $s | .routine_type = $rt | .description = $d | .management = $m' \
			"$state_file" >"$tmp" && mv "$tmp" "$state_file"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# _create_core_routine_issues <slug>
# Creates GitHub issues for each core routine using routine-log-helper.sh.
# Skipped for local-only repos. Idempotent — routine-log-helper checks state.
# Issues are labelled routine-tracking so the pulse skips them.
# ---------------------------------------------------------------------------
_create_core_routine_issues() {
	local slug="$1"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would create GitHub issues for core routines in: $slug"
		return 0
	fi

	local log_helper="${SCRIPT_DIR}/routine-log-helper.sh"
	if [[ ! -f "$log_helper" ]]; then
		print_warning "routine-log-helper.sh not found — skipping issue creation"
		return 0
	fi

	if [[ ! -f "${SCRIPT_DIR}/routines/core-routines.sh" ]]; then
		print_warning "core-routines.sh not found — skipping issue creation"
		return 0
	fi

	# Ensure labels exist on the repo
	gh label create "routines" --repo "$slug" --description "Routine tracking" --color "0E8A16" 2>/dev/null || true
	gh label create "core" --repo "$slug" --description "Framework-managed routine" --color "1D76DB" 2>/dev/null || true
	gh label create "routine-tracking" --repo "$slug" --description "Execution tracking issue — not a task (pulse skips these)" --color "BFDADC" 2>/dev/null || true

	# shellcheck disable=SC1091  # sourced file path is dynamic but verified above
	source "${SCRIPT_DIR}/routines/core-routines.sh"

	# Detect local timezone for schedule descriptions
	local tz_name
	tz_name=$(_detect_timezone)

	local rid enabled title schedule estimate script rtype timezone
	while IFS='|' read -r rid enabled title schedule estimate script rtype timezone; do
		[[ -z "$rid" ]] && continue
		# Extract short title (before the em dash if present)
		local short_title
		short_title=$(echo "$title" | sed 's/ —.*//')

		# Generate human-readable schedule
		local human_schedule
		local schedule_timezone=""
		schedule_timezone="${timezone:-$tz_name}"
		human_schedule=$(_humanise_schedule "$schedule" "$schedule_timezone")

		# Detect whether this routine already has a tracking state file. If it
		# does, we must NOT fire the initial `update --status success` body-
		# rebuild trigger, because that call appends a fake run entry, bumps
		# streak counters, and drags avg_duration toward zero. The
		# `create-issue` call itself is already idempotent (see t1964).
		local state_file="${HOME}/.aidevops/.agent-workspace/cron/${rid}/routine-state.json"
		local preexisting_state=false
		[[ -f "$state_file" ]] && preexisting_state=true

		if [[ "$preexisting_state" == true ]]; then
			print_info "Tracking issue for ${rid}: ${short_title} already exists — refreshing description only"
		else
			print_info "Creating tracking issue for ${rid}: ${short_title}..."
		fi

		local issue_num
		issue_num=$(bash "$log_helper" create-issue "$rid" \
			--repo "$slug" \
			--title "${rid}: ${short_title}" \
			--schedule "${human_schedule}" \
			--type "$rtype" 2>&1 | tail -1)

		# Add routine-tracking label so the pulse skips these issues
		if [[ -n "$issue_num" ]] && [[ "$issue_num" =~ ^[0-9]+$ ]]; then
			gh issue edit "$issue_num" --repo "$slug" --add-label "routine-tracking" 2>/dev/null || true
			# Store description in state so _build_issue_body includes it
			_store_routine_description "$rid" "$short_title" "$human_schedule" "$script" "$rtype"
			if [[ "$preexisting_state" == true ]]; then
				# Refresh the issue body with the updated description text without
				# recording a new run entry — prevents metric pollution (t1964)
				# while making the "refreshing description only" log truthful
				# (GH#18616). Streak and avg_duration are preserved.
				bash "$log_helper" refresh-description "$rid" 2>/dev/null || true
			else
				# Fresh init: record a synthetic first entry so the metrics table
				# is populated before the routine's first real run.
				bash "$log_helper" update "$rid" --status success --duration 0 2>/dev/null || true
			fi
		fi
	done < <(get_core_routine_entries)

	print_success "Core routine issues created in: $slug"
	return 0
}

# ---------------------------------------------------------------------------
# init_personal
# Creates <username>/aidevops-routines on GitHub (private), clones, scaffolds.
# ---------------------------------------------------------------------------
init_personal() {
	_check_gh_auth || return 1

	local username
	username=$(gh api user --jq '.login' 2>/dev/null)
	if [[ -z "$username" ]]; then
		print_error "Could not detect GitHub username"
		return 1
	fi

	local slug="${username}/aidevops-routines"
	local repo_path="${GIT_PARENT}/aidevops-routines"
	local existing_remote=false
	if [[ -d "$repo_path/.git" ]] && git -C "$repo_path" remote get-url origin &>/dev/null; then
		existing_remote=true
	fi

	print_info "Creating personal routines repo: $slug"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would create: gh repo create $slug --private"
		print_info "[dry-run] Would clone to: $repo_path"
		scaffold_repo "$repo_path"
		register_repo "$repo_path" "$slug"
		return 0
	fi

	_ensure_gh_repo "$slug" "Private routines"
	_ensure_cloned "$slug" "$repo_path"
	register_repo "$repo_path" "$slug"
	if [[ "$existing_remote" == true ]]; then
		_publish_routines_scaffold "$repo_path" || print_warning "Routines scaffold publication deferred"
	else
		scaffold_repo "$repo_path"
		_commit_and_push "$repo_path"
	fi
	_create_core_routine_issues "$slug"

	print_success "Personal routines repo ready: $repo_path"
	return 0
}

# ---------------------------------------------------------------------------
# init_org <org_name>
# Creates <org>/aidevops-routines on GitHub (private), clones, scaffolds.
# ---------------------------------------------------------------------------
init_org() {
	local org_name="$1"

	_check_gh_auth || return 1

	local slug="${org_name}/aidevops-routines"
	local repo_path="${GIT_PARENT}/${org_name}-aidevops-routines"
	local existing_remote=false
	if [[ -d "$repo_path/.git" ]] && git -C "$repo_path" remote get-url origin &>/dev/null; then
		existing_remote=true
	fi

	print_info "Creating org routines repo: $slug"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would create: gh repo create $slug --private"
		print_info "[dry-run] Would clone to: $repo_path"
		scaffold_repo "$repo_path"
		register_repo "$repo_path" "$slug"
		return 0
	fi

	_ensure_gh_repo "$slug" "Private routines (${org_name})"
	_ensure_cloned "$slug" "$repo_path"
	register_repo "$repo_path" "$slug"
	if [[ "$existing_remote" == true ]]; then
		_publish_routines_scaffold "$repo_path" || print_warning "Routines scaffold publication deferred"
	else
		scaffold_repo "$repo_path"
		_commit_and_push "$repo_path"
	fi
	_create_core_routine_issues "$slug"

	print_success "Org routines repo ready: $repo_path"
	return 0
}

# ---------------------------------------------------------------------------
# init_local
# Creates a local-only git repo (no remote), scaffolds, registers with local_only: true.
# ---------------------------------------------------------------------------
init_local() {
	local repo_path="${GIT_PARENT}/aidevops-routines"
	local slug="local/aidevops-routines"

	print_info "Creating local-only routines repo at: $repo_path"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would git init at: $repo_path"
		scaffold_repo "$repo_path"
		register_repo "$repo_path" "$slug" "true"
		return 0
	fi

	if [[ ! -d "$repo_path/.git" ]]; then
		mkdir -p "$repo_path"
		git -C "$repo_path" init
		print_success "Initialized local git repo at: $repo_path"
	else
		print_info "Repo already exists at: $repo_path"
	fi

	scaffold_repo "$repo_path"
	register_repo "$repo_path" "$slug" "true"

	# Initial commit
	(
		cd "$repo_path"
		git add -A
		if ! git diff --cached --quiet; then
			git commit -m "chore: scaffold aidevops-routines repo"
		fi
	)

	print_success "Local routines repo ready: $repo_path"
	return 0
}

# ---------------------------------------------------------------------------
# _prompt_org <org>
# Prompts user to create org routines repo. Returns 0 to create, 1 to skip.
# ---------------------------------------------------------------------------
_prompt_org() {
	local org="$1"
	local org_slug="${org}/aidevops-routines"

	# Check if already registered
	if command -v jq &>/dev/null && [[ -f "$REPOS_JSON" ]]; then
		if jq -e --arg slug "$org_slug" '.initialized_repos[] | select(.slug == $slug)' "$REPOS_JSON" &>/dev/null; then
			print_info "Org routines repo already registered: $org_slug"
			return 1
		fi
	fi

	print_info "Create routines repo for org: $org? [y/N] "
	local response
	read -r response || response="n"
	case "$response" in
	[yY] | [yY][eE][sS])
		return 0
		;;
	*)
		print_info "Skipping org: $org"
		return 1
		;;
	esac
}

# ---------------------------------------------------------------------------
# detect_and_create_all
# Setup integration: detect username + admin orgs, create all routines repos.
# Non-interactive mode: scaffolds local repo + creates personal GH remote only.
# Interactive mode: personal repo + prompts for each admin org.
# Falls back to local-only if gh CLI is unavailable.
# ---------------------------------------------------------------------------
detect_and_create_all() {
	local non_interactive="${1:-false}"

	# If gh is unavailable, fall back to local-only scaffolding so the repo
	# structure exists even without a GitHub remote.
	if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null 2>&1; then
		print_warning "gh CLI not available or not authenticated — creating local-only routines repo"
		init_local
		return 0
	fi

	local username
	username=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$username" ]]; then
		print_warning "Could not detect GitHub username — creating local-only routines repo"
		init_local
		return 0
	fi

	# Always create personal repo (private GH remote + local clone)
	init_personal

	if [[ "$non_interactive" == "true" ]]; then
		print_info "Non-interactive mode: skipping org repos (run 'aidevops init-routines --org <name>')"
		return 0
	fi

	# Detect admin orgs
	local admin_orgs
	admin_orgs=$(gh api user/memberships/orgs --jq '.[] | select(.role == "admin") | .organization.login' 2>/dev/null || echo "")

	[[ -z "$admin_orgs" ]] && return 0

	while IFS= read -r org; do
		[[ -z "$org" ]] && continue
		if _prompt_org "$org"; then
			init_org "$org"
		fi
	done <<<"$admin_orgs"

	return 0
}

# ---------------------------------------------------------------------------
# show_help
# ---------------------------------------------------------------------------
show_help() {
	cat <<'HELPEOF'
init-routines-helper.sh -- scaffold a private routines repo

Usage:
  init-routines-helper.sh [options]

Options:
  --org <name>   Create per-org variant: <org>/aidevops-routines (always private)
  --local        Create local-only repo (no remote, local_only: true in repos.json)
  --dry-run      Print what would be done without making changes
  --help         Show this help message

Without flags: creates personal <username>/aidevops-routines (always private).

Scaffolded structure:
  ~/Git/aidevops-routines/
  |- TODO.md              # Routine definitions (core + user) with repeat: fields
  |- routines/
  |  |- core/             # Framework-managed routine descriptions (r901+)
  |  |  |- r901.md        # Supervisor pulse
  |  |  |- r902.md        # Auto-update
  |  |  `- ...            # 12 core routines total
  |  `- custom/           # User routine descriptions (r001-r899, survives updates)
  |     `- README.md
  |- .gitignore
  `- .github/
     `- ISSUE_TEMPLATE/
        `- routine.md

For repos with a GitHub remote, a tracking issue is created for each
core routine via routine-log-helper.sh (idempotent, skipped if exists).

The repo is registered in ~/.config/aidevops/repos.json with:
  pulse: true, priority: "tooling"

Privacy: always private -- no flag to make public.

Examples:
  init-routines-helper.sh                  # Personal repo
  init-routines-helper.sh --org mycompany  # Org repo
  init-routines-helper.sh --local          # Local-only (no remote)
  init-routines-helper.sh --dry-run        # Preview without changes
HELPEOF
	return 0
}

# ---------------------------------------------------------------------------
# _parse_args <args...>
# Parse command-line arguments. Sets MODE and ORG_NAME globals.
# ---------------------------------------------------------------------------
MODE="personal"
ORG_NAME=""

_parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--org)
			MODE="org"
			ORG_NAME="${2:-}"
			if [[ -z "$ORG_NAME" ]]; then
				print_error "--org requires an organization name"
				exit 1
			fi
			shift 2
			;;
		--local)
			MODE="local"
			shift
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--help | -h)
			show_help
			exit 0
			;;
		*)
			print_error "Unknown option: $1"
			echo "Run with --help for usage."
			exit 1
			;;
		esac
	done
	return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	_parse_args "$@"

	case "$MODE" in
	personal)
		init_personal
		;;
	org)
		init_org "$ORG_NAME"
		;;
	local)
		init_local
		;;
	esac

	return 0
}

# Only run main when executed directly, not when sourced by _routines.sh
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
