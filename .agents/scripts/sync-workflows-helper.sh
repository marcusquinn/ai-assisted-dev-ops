#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# sync-workflows-helper.sh — opt-in resync of framework workflows across registered repos.
#
# Phase 2 of workflow drift elimination (t2779, GH#20649).
# Partner to check-workflows-helper.sh (Phase 1, t2778). Reads classifications
# from the detector and, per repo, either installs or refreshes the canonical
# caller template at `.github/workflows/<name>.yml`.
#
# Currently managed workflows (synced by default):
#   - issue-sync.yml         (template: issue-sync-caller.yml)
#   - review-bot-gate.yml    (template: review-bot-gate-caller.yml, GH#20727)
#   - maintainer-gate.yml    (template: maintainer-gate-caller.yml, GH#21154)
#   - linked-issue-check.yml (template: linked-issue-check-caller.yml, GH#28844)
#
# Default mode is --dry-run. Pass --apply to actually write, commit, push, and
# open a PR in each target repo.
#
# Design invariants:
#   - Never touch the aidevops repo itself (CURRENT/SELF-CALLER is not drift).
#   - Each repo operation is isolated: its own branch, its own PR, its own
#     commit. No cross-repo atomicity assumed.
#   - Never push directly to main. Always via PR.
#   - Preserve intentional @ref pinning: if the repo's current caller pins a
#     specific ref and the new template's ref would change it, keep the repo's
#     choice unless --force-ref is set.
#   - Never mutate registered canonical checkouts. Reuse a matching caller-owned
#     linked worktree or create a fresh framework-owned linked worktree.
#   - Skip linked worktrees with uncommitted changes.
#
# Exit codes:
#   0  all targeted repos processed successfully (or no work needed)
#   1  one or more repos failed (check report for per-repo status)
#   2  config error (repos.json missing, jq unavailable, template missing,
#      check-workflows-helper.sh unavailable)

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
if [[ -f "$SELF_DIR/shared-constants.sh" ]]; then
	source "$SELF_DIR/shared-constants.sh"
fi

# shellcheck source=/dev/null
# gh wrappers inject signature footers and route around GraphQL rate limits.
# Mandatory — this script ships as part of aidevops so the wrappers are
# always available; a missing file indicates a broken install.
if [[ -f "$SELF_DIR/shared-gh-wrappers.sh" ]]; then
	source "$SELF_DIR/shared-gh-wrappers.sh"
else
	printf '[%s] WARN: shared-gh-wrappers.sh not found — PR creation will fail\n' \
		"$SCRIPT_NAME" >&2
fi

# Interpreted escapes — shared-constants.sh uses literal strings which printf
# prints verbatim. Override locally with ANSI-C quoted variants so printf
# emits actual control codes.
_C_GREEN=$'\033[0;32m'
_C_RED=$'\033[0;31m'
_C_YELLOW=$'\033[1;33m'
_C_BLUE=$'\033[0;34m'
_C_NC=$'\033[0m'

readonly REPOS_JSON="$HOME/.config/aidevops/repos.json"
readonly CHECK_HELPER="$SELF_DIR/check-workflows-helper.sh"
readonly MANAGED_BLOCK_HELPER="$SELF_DIR/managed-markdown-block-helper.py"
readonly CONTRIBUTING_POLICY_TEMPLATE_NAME="issue-first-pr-contributing.md"
readonly LINKED_ISSUE_WORKFLOW_NAME="linked-issue-check"

# Known managed workflows — each entry is workflow_file:template_file.
# Mirrors _KNOWN_WORKFLOWS in check-workflows-helper.sh.
# GH#20727: review-bot-gate added.
# GH#21154: maintainer-gate added (layer-1 defense-in-depth propagation).
# GH#21877: loc-badge added (runner input parity).
# GH#28844: linked-issue-check added (external contribution visibility).
readonly _SYNC_KNOWN_WORKFLOWS=(
	"issue-sync.yml:issue-sync-caller.yml"
	"review-bot-gate.yml:review-bot-gate-caller.yml"
	"maintainer-gate.yml:maintainer-gate-caller.yml"
	"loc-badge.yml:loc-badge-caller.yml"
	"linked-issue-check.yml:linked-issue-check-caller.yml"
)

# Output mode constants.
readonly _STATUS_SKIPPED="SKIPPED"
readonly _STATUS_PLANNED="PLANNED"
readonly _STATUS_APPLIED="APPLIED"
readonly _STATUS_FAILED="FAILED"

# Classification labels (must match check-workflows-helper.sh).
readonly _CLASS_DRIFTED='DRIFTED/CALLER'
readonly _CLASS_NEEDS_MIGRATION='NEEDS-MIGRATION'
readonly _CLASS_CURRENT_CALLER='CURRENT/CALLER'
readonly _CLASS_DRIFTED_REUSABLE='DRIFTED/REUSABLE'
readonly _CLASS_NO_WORKFLOW='NO-WORKFLOW'
readonly _CLASS_LOCAL_ONLY='LOCAL-ONLY'

readonly _DEFAULT_WORKFLOW_REUSABLE_REPO="marcusquinn/aidevops"
readonly _DEFAULT_WORKFLOW_REUSABLE_REF="main"

# Canonical default branch name used in the template and as preflight fallback.
readonly _BRANCH_DEFAULT_NAME="main"

# ─── Helpers ────────────────────────────────────────────────────────────────

_die() {
	local _msg="$1"
	local _code="${2:-2}"
	printf '[%s] %sERROR%s: %s\n' "$SCRIPT_NAME" "$_C_RED" "$_C_NC" "$_msg" >&2
	exit "$_code"
}

_escape_sed_replacement() {
	local _text="$1"
	printf '%s' "$_text" | sed 's/[&|]/\\&/g'
	return 0
}

_normalise_reusable_ref() {
	local _ref="$1"
	_ref="${_ref#@}"
	printf '%s\n' "$_ref"
	return 0
}

_validate_reusable_repo() {
	local _repo="$1"
	if [[ ! "$_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		_die "invalid workflow_reusable_repo: $_repo"
	fi
	return 0
}

_validate_reusable_ref() {
	local _ref="$1"
	if [[ -z "$_ref" || "$_ref" =~ [[:space:][:cntrl:]] ]]; then
		_die "invalid workflow_reusable_ref: $_ref"
	fi
	return 0
}

_warn() {
	local _msg="$1"
	printf '[%s] %sWARN%s: %s\n' "$SCRIPT_NAME" "$_C_YELLOW" "$_C_NC" "$_msg" >&2
	return 0
}

_info() {
	local _msg="$1"
	printf '[%s] %s\n' "$SCRIPT_NAME" "$_msg" >&2
	return 0
}

_is_linked_worktree() {
	local _path="$1"
	local _git_dir _common_dir _path_abs
	_git_dir=$(git -C "$_path" rev-parse --absolute-git-dir 2>/dev/null) || return 1
	_common_dir=$(git -C "$_path" rev-parse --git-common-dir 2>/dev/null) || return 1
	if [[ "$_common_dir" != /* ]]; then
		_path_abs=$(cd "$_path" && pwd -P) || return 1
		_common_dir="${_path_abs}/${_common_dir}"
	fi
	[[ "$_git_dir" != "$_common_dir" ]] || return 1
	return 0
}

_github_slug_from_remote_url() {
	local _url="$1"
	local _slug=""
	case "$_url" in
	git@github.com:*) _slug="${_url#git@github.com:}" ;;
	ssh://git@github.com/*) _slug="${_url#ssh://git@github.com/}" ;;
	https://github.com/*) _slug="${_url#https://github.com/}" ;;
	http://github.com/*) _slug="${_url#http://github.com/}" ;;
	git://github.com/*) _slug="${_url#git://github.com/}" ;;
	*) return 1 ;;
	esac
	_slug="${_slug%%\?*}"
	_slug="${_slug%%#*}"
	_slug="${_slug%/}"
	_slug="${_slug%.git}"
	[[ -n "$_slug" && "$_slug" == */* && "${_slug#*/}" != */* ]] || return 1
	printf '%s\n' "$_slug"
	return 0
}

# Resolve the remote that represents the registry's GitHub repository. Prefer
# an exact fetch+push URL identity match; retain origin only for local mirrors
# where no configured remote is parseable as GitHub at all.
_resolve_github_remote() {
	local _repo_path="$1"
	local _expected_slug="$2"
	local _expected_lower
	_expected_lower=$(printf '%s' "$_expected_slug" | tr '[:upper:]' '[:lower:]') || return 1
	local _remote_names
	_remote_names=$(git -C "$_repo_path" remote 2>/dev/null) || return 1
	local _remote=""
	local _fetch_url="" _push_url=""
	local _fetch_slug="" _push_slug=""
	local _fetch_lower="" _push_lower=""
	local _candidate=""
	local _github_seen=0
	while IFS= read -r _remote; do
		[[ -n "$_remote" ]] || continue
		_fetch_url=$(git -C "$_repo_path" config --get "remote.${_remote}.url" 2>/dev/null || true)
		_push_url=$(git -C "$_repo_path" config --get "remote.${_remote}.pushurl" 2>/dev/null || true)
		[[ -n "$_push_url" ]] || _push_url="$_fetch_url"
		_fetch_slug=$(_github_slug_from_remote_url "$_fetch_url" 2>/dev/null || true)
		_push_slug=$(_github_slug_from_remote_url "$_push_url" 2>/dev/null || true)
		if [[ -n "$_fetch_slug" || -n "$_push_slug" ]]; then
			_github_seen=1
		fi
		[[ -n "$_fetch_slug" && -n "$_push_slug" ]] || continue
		_fetch_lower=$(printf '%s' "$_fetch_slug" | tr '[:upper:]' '[:lower:]') || return 1
		_push_lower=$(printf '%s' "$_push_slug" | tr '[:upper:]' '[:lower:]') || return 1
		[[ "$_fetch_lower" == "$_expected_lower" && "$_push_lower" == "$_expected_lower" ]] || continue
		if [[ "$_remote" == "origin" ]]; then
			printf '%s\n' "$_remote"
			return 0
		fi
		[[ -n "$_candidate" ]] || _candidate="$_remote"
	done <<<"$_remote_names"
	if [[ -n "$_candidate" ]]; then
		printf '%s\n' "$_candidate"
		return 0
	fi
	if [[ "$_github_seen" -eq 0 ]] && git -C "$_repo_path" remote get-url origin >/dev/null 2>&1; then
		printf 'origin\n'
		return 0
	fi
	return 1
}

_remote_default_ref() {
	local _remote="$1"
	local _default_branch="$2"
	printf '%s/%s\n' "$_remote" "$_default_branch"
	return 0
}

_worktree_for_branch() {
	local _repo_path="$1"
	local _branch="$2"
	local _line _candidate=""
	while IFS= read -r _line; do
		case "$_line" in
		worktree\ *) _candidate="${_line#worktree }" ;;
		"branch refs/heads/${_branch}")
			printf '%s\n' "$_candidate"
			return 0
			;;
		esac
	done < <(git -C "$_repo_path" worktree list --porcelain 2>/dev/null)
	return 1
}

# Refresh a canonical repository's remote-tracking branch from linked-worktree
# context so the canonical Git guard remains intact. Bootstrap a short-lived
# detached worktree when the repository has no linked worktree yet.
_refresh_remote_from_linked_context() {
	local _repo_path="$1"
	local _remote="$2"
	local _default_branch="$3"
	local _base_dir="$4"
	local _slug="$5"
	local _fetch_path=""
	local _line _candidate
	while IFS= read -r _line; do
		case "$_line" in
		worktree\ *)
			_candidate="${_line#worktree }"
			if [[ -d "$_candidate" ]] && _is_linked_worktree "$_candidate"; then
				_fetch_path="$_candidate"
				break
			fi
			;;
		esac
	done < <(git -C "$_repo_path" worktree list --porcelain 2>/dev/null)

	local _bootstrap_path=""
	if [[ -z "$_fetch_path" ]]; then
		local _safe_slug
		_safe_slug=$(printf '%s' "$_slug" | sed 's|[^A-Za-z0-9._-]|-|g')
		mkdir -p "$_base_dir" || return 1
		_bootstrap_path="${_base_dir}/.${_safe_slug}-workflow-sync-fetch-$$"
		[[ ! -e "$_bootstrap_path" ]] || return 1
		git -C "$_repo_path" worktree add -q --detach \
			"$_bootstrap_path" HEAD >/dev/null 2>&1 || return 1
		_fetch_path="$_bootstrap_path"
	fi

	local _fetch_rc=0
	local _cleanup_rc=0
	git -C "$_fetch_path" fetch --no-tags --quiet "$_remote" \
		"+refs/heads/${_default_branch}:refs/remotes/${_remote}/${_default_branch}" \
		>/dev/null 2>&1 || _fetch_rc=$?
	if [[ -n "$_bootstrap_path" ]]; then
		git -C "$_fetch_path" worktree remove --force "$_bootstrap_path" \
			>/dev/null 2>&1 || _cleanup_rc=$?
	fi
	[[ "$_fetch_rc" -eq 0 && "$_cleanup_rc" -eq 0 ]] || return 1
	return 0
}

# _prepare_apply_worktree <slug> <classified-path> <branch>
# Emits the safe linked worktree path used for mutation.
_prepare_apply_worktree() {
	local _slug="$1"
	local _classified_path="$2"
	local _branch="$3"
	if _is_linked_worktree "$_classified_path"; then
		if command -v is_worktree_owned_by_others >/dev/null 2>&1 && \
			is_worktree_owned_by_others "$_classified_path"; then
			return 1
		fi
		printf '%s\n' "$_classified_path"
		return 0
	fi
	git -C "$_classified_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

	local _remote
	_remote=$(_resolve_github_remote "$_classified_path" "$_slug") || return 1
	local _default_branch
	_default_branch=$(git -C "$_classified_path" symbolic-ref --short "refs/remotes/${_remote}/HEAD" 2>/dev/null || true)
	_default_branch="${_default_branch#"${_remote}"/}"
	[[ -z "$_default_branch" ]] && _default_branch="$_BRANCH_DEFAULT_NAME"

	local _existing
	_existing=$(_worktree_for_branch "$_classified_path" "$_branch") || _existing=""
	if [[ -n "$_existing" ]]; then
		_is_linked_worktree "$_existing" || return 1
		if command -v is_worktree_owned_by_others >/dev/null 2>&1 && \
			is_worktree_owned_by_others "$_existing"; then
			return 1
		fi
		printf '%s\n' "$_existing"
		return 0
	fi

	local _base_dir="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME:+$HOME/Git/_worktrees}}"
	[[ -n "$_base_dir" ]] || return 1
	local _safe_name
	_safe_name=$(printf '%s-%s' "$_slug" "$_branch" | sed 's|[^A-Za-z0-9._-]|-|g')
	local _worktree_path="${_base_dir}/${_safe_name}"
	local _default_ref
	_default_ref=$(_remote_default_ref "$_remote" "$_default_branch")
	mkdir -p "$_base_dir" || return 1
	[[ ! -e "$_worktree_path" ]] || return 1
	_refresh_remote_from_linked_context \
		"$_classified_path" "$_remote" "$_default_branch" "$_base_dir" "$_slug" || return 1
	git -C "$_classified_path" worktree add -q -B "$_branch" \
		"$_worktree_path" "$_default_ref" >/dev/null 2>&1 || return 1
	if command -v register_worktree >/dev/null 2>&1; then
		register_worktree "$_worktree_path" "$_branch" --task workflow-sync || true
	fi
	printf '%s\n' "$_worktree_path"
	return 0
}

_usage() {
	cat <<'EOF'

sync-workflows-helper.sh — resync drifted framework workflows (t2779, GH#20649)

Reads classifications from check-workflows-helper.sh and, per repo × workflow,
installs or refreshes the canonical caller template. Managed workflows include
issue-sync.yml, review-bot-gate.yml, maintainer-gate.yml, loc-badge.yml, and
linked-issue-check.yml.

Default is --dry-run. Pass --apply to write, commit, push, and open PRs.

Usage:
  sync-workflows-helper.sh [--apply] [--repo OWNER/REPO] [--workflow NAME]
                           [--install-missing] [--issue NUMBER]
                           [--force-ref] [--ref REF] [--branch NAME] [--json]
  sync-workflows-helper.sh --help

Options:
  --apply           Actually perform the migration. Without this, only prints
                    what would happen (dry-run is the default for safety).
  --repo SLUG       Limit to a single repo. Example: --repo owner/repo.
  --workflow NAME   Limit to a single managed workflow.
  --install-missing Include NO-WORKFLOW rows. Requires --workflow and filters
                    out local-only, external-upstream, archived, inaccessible,
                    and non-ADMIN/non-MAINTAIN repositories.
  --issue NUMBER    Rollout task number for commit/PR traceability.
  --force-ref       Overwrite existing @ref pinning with the template's default.
                    Without this, existing pins (@v3.9.0, @<sha>) are preserved.
  --ref REF         Explicit @ref for new installs (default: @main).
  --branch NAME     Branch name prefix (default: chore/workflow-sync-YYYYMMDD).
  --json            Emit one JSON object per repo × workflow describing outcome.
  -h, --help        Show this help.

Exit codes:
  0  no work needed OR all targets succeeded
  1  one or more repos failed
  2  config error

Examples:
  # See what would happen across all repos (all workflows):
  sync-workflows-helper.sh

  # Migrate review-bot-gate only for one repo:
  sync-workflows-helper.sh --apply --repo exampleorg/examplerepo --workflow review-bot-gate

  # Safely install one missing workflow across eligible managed repositories:
  sync-workflows-helper.sh --workflow linked-issue-check --install-missing

  # Migrate all drifted/needs-migration repos, pin to v3.9.0:
  sync-workflows-helper.sh --apply --ref @v3.9.0

EOF
	return 0
}

# ─── Template Resolution ────────────────────────────────────────────────────

# _resolve_canonical_template <template_filename>
# e.g. _resolve_canonical_template "review-bot-gate-caller.yml"
_resolve_canonical_template() {
	local _template_filename="$1"
	local _candidates=(
		"$HOME/.aidevops/agents/templates/workflows/${_template_filename}"
		"$SELF_DIR/../templates/workflows/${_template_filename}"
	)
	local _path
	for _path in "${_candidates[@]}"; do
		if [[ -f "$_path" ]]; then
			printf '%s\n' "$_path"
			return 0
		fi
	done
	return 1
}

_resolve_contributing_policy_template() {
	local _candidates=(
		"$HOME/.aidevops/agents/templates/${CONTRIBUTING_POLICY_TEMPLATE_NAME}"
		"$SELF_DIR/../templates/${CONTRIBUTING_POLICY_TEMPLATE_NAME}"
	)
	local _path
	for _path in "${_candidates[@]}"; do
		if [[ -f "$_path" ]]; then
			printf '%s\n' "$_path"
			return 0
		fi
	done
	return 1
}

# Extract the @ref token from a caller YAML's `uses:` line, e.g. "@main",
# "@v3.9.0", "@<sha>". Empty on failure.
_extract_ref_pin() {
	local _file="$1"
	[[ -f "$_file" ]] || return 0
	grep -oE 'uses:[[:space:]]*[^[:space:]]+@[^[:space:]]+' "$_file" 2>/dev/null |
		head -1 | sed -E 's|.*@([^[:space:]]+)$|@\1|'
	return 0
}

# Return success only for reusable workflows that fetch framework helpers from
# the configured aidevops repository. Self-contained workflows must not inherit
# helper provenance inputs merely because they expose an aidevops_ref input for
# API consistency.
_workflow_fetches_framework_helpers() {
	local _workflow_name="$1"
	case "$_workflow_name" in
	issue-sync | review-bot-gate | loc-badge) return 0 ;;
	*) return 1 ;;
	esac
}

# Render the caller template with a target reusable repo/ref, writing to stdout.
_render_template_with_target() {
	local _template="$1"
	local _repo="$2"
	local _ref="$3"
	local _workflow_name="$4"
	# Escape sed replacement special chars (&, |) before interpolation.
	local _repo_escaped _ref_escaped
	_repo_escaped=$(_escape_sed_replacement "$_repo")
	_ref_escaped=$(_escape_sed_replacement "${_ref#@}")
	# Template ships with `marcusquinn/aidevops@main` by default; rewrite the
	# executable `uses:` target and any managed comment/reference path so
	# sync-generated org-owned callers are byte-comparable by check-workflows.
	local _rendered
	_rendered=$(sed -E \
		-e 's|(uses:[[:space:]]*)marcusquinn/aidevops(/\.github/workflows/[^@[:space:]]+)@[^[:space:]]+|\1'"$_repo_escaped"'\2@'"$_ref_escaped"'|' \
		-e 's|marcusquinn/aidevops(/\.github/workflows/[^[:space:]]+)|'"$_repo_escaped"'\1|g' \
		-e 's|^(      aidevops_ref:).*$|\1 '"$_ref_escaped"'|' \
		"$_template")
	# Helper-bearing reusable workflows must bind helper checkout provenance to
	# the configured mirror. Self-contained workflows keep their original caller
	# contract even when they expose an aidevops_ref input for API consistency.
	if [[ "$_repo" != "$_DEFAULT_WORKFLOW_REUSABLE_REPO" ]] && \
		_workflow_fetches_framework_helpers "$_workflow_name"; then
		printf '%s\n' "$_rendered" | grep -qE '^      aidevops_ref:' || return 1
		_rendered=$(printf '%s\n' "$_rendered" | sed -E \
			's|^(      aidevops_ref:.*)$|      aidevops_repository: '"$_repo_escaped"'\n\1|'
		)
		_rendered=$(_inject_mirror_read_secret "$_rendered")
	fi
	printf '%s\n' "$_rendered"
	return 0
}

_inject_mirror_read_secret() {
	local _content="$1"
	if printf '%s\n' "$_content" | grep -qE '^    secrets: inherit$'; then
		printf '%s\n' "$_content" | sed -E \
			's|^    secrets: inherit$|    secrets:\
      AIDEVOPS_READ_TOKEN: ${{ secrets.AIDEVOPS_READ_TOKEN }}|'
	else
		printf '%s\n' "$_content" | sed -E \
			's|^    secrets:$|    secrets:\
      AIDEVOPS_READ_TOKEN: ${{ secrets.AIDEVOPS_READ_TOKEN }}|'
	fi
	return 0
}

_mirror_supports_helper_provenance() {
	local _repo="$1"
	local _workflow_name="$2"
	local _ref="$3"
	local _path _reusable_path _reusable_content
	_path=$(jq -r --arg s "$_repo" \
		'.initialized_repos[]? | select(.slug == $s) | .path // empty' \
		"$REPOS_JSON" 2>/dev/null | head -n 1)
	_reusable_path=".github/workflows/${_workflow_name}-reusable.yml"
	[[ -n "$_path" ]] || return 1
	git -C "$_path" rev-parse --git-dir >/dev/null 2>&1 || return 1
	_reusable_content=$(git -C "$_path" show "${_ref#@}:${_reusable_path}" 2>/dev/null) || return 1
	if grep -qE '^      aidevops_repository:' <<<"$_reusable_content" && \
		grep -qE '^      AIDEVOPS_READ_TOKEN:' <<<"$_reusable_content"; then
		return 0
	fi
	return 1
}

# Rewrite `branches: [main]` → `branches: [<default_branch>]` in caller YAML content.
# No-op when default branch is `main`. Emits rewritten content on stdout.
# Used after preflight resolves the downstream default branch.
_rewrite_content_branch_filter() {
	local _content="$1"
	local _branch="$2"
	if [[ "$_branch" == "$_BRANCH_DEFAULT_NAME" ]]; then
		printf '%s\n' "$_content"
		return 0
	fi
	local _branch_escaped
	_branch_escaped=$(printf '%s' "$_branch" | sed 's/[&|/]/\\&/g')
	printf '%s\n' "$_content" | \
		sed -E "s|^([[:space:]]+branches:) \[${_BRANCH_DEFAULT_NAME}\]$|\1 [${_branch_escaped}]|"
	return 0
}

# ─── Runner Override Injection ──────────────────────────────────────────────

_read_workflow_reusable_field() {
	local _slug="$1"
	local _field="$2"
	jq -r --arg s "$_slug" --arg f "$_field" '
		([.initialized_repos[]? | select(.slug == $s) | .[$f] // empty] | first // "") as $repo_value
		| if $repo_value != "" then $repo_value else (.[$f] // empty) end
	' "$REPOS_JSON" 2>/dev/null
	return 0
}

_workflow_reusable_repo_for_slug() {
	local _slug="$1"
	local _repo
	_repo=$(_read_workflow_reusable_field "$_slug" "workflow_reusable_repo")
	[[ -z "$_repo" ]] && _repo="$_DEFAULT_WORKFLOW_REUSABLE_REPO"
	_validate_reusable_repo "$_repo"
	printf '%s\n' "$_repo"
	return 0
}

_workflow_reusable_ref_for_slug() {
	local _slug="$1"
	local _ref
	_ref=$(_read_workflow_reusable_field "$_slug" "workflow_reusable_ref")
	[[ -z "$_ref" ]] && _ref="$_DEFAULT_WORKFLOW_REUSABLE_REF"
	_ref=$(_normalise_reusable_ref "$_ref")
	_validate_reusable_ref "$_ref"
	printf '%s\n' "$_ref"
	return 0
}

# _read_runner_field <slug>
# Reads the optional "runner" field for a slug from repos.json.
# Emits the runner label on stdout, or nothing if the field is absent.
_read_runner_field() {
	local _slug="$1"
	jq -r --arg s "$_slug" \
		'.initialized_repos[]? | select(.slug == $s) | .runner // empty' \
		"$REPOS_JSON" 2>/dev/null
	return 0
}

# _inject_runner_in_content <content> <runner_label>
# Injects `runner: <label>` into the caller template's `with:` block.
#   - If the template already has a `    with:` block, appends runner as the
#     first key inside it (so it survives further key additions).
#   - If no `    with:` block exists, inserts one after the `    uses:` line.
# Emits the modified content on stdout.
_inject_runner_in_content() {
	local _content="$1"
	local _runner="$2"
	local _runner_escaped
	_runner_escaped=$(printf '%s' "$_runner" | sed 's/[&|/]/\\&/g')

	# Does the template already have a `    with:` block?
	if printf '%s\n' "$_content" | grep -qE '^    with:$'; then
		# Append runner as the first entry inside the existing with: block.
		printf '%s\n' "$_content" | \
			sed -E "s|^(    with:)$|\\1\n      runner: ${_runner_escaped}|"
	else
		# No with: block — inject one after the uses: line.
		printf '%s\n' "$_content" | \
			sed -E "s|^(    uses:[[:space:]]*[^[:space:]]+/\.github/workflows/.+)$|\\1\n    with:\n      runner: ${_runner_escaped}|"
	fi
	return 0
}

# _read_runner_from_file <workflow_file>
# Extracts the existing `      runner: <value>` value from a caller workflow.
# Emits the runner string on stdout, or empty if the line is absent or the
# file is unreadable. Mirrors the 6-space indent that `_inject_runner_in_content`
# writes and that `_normalize_wf_for_compare` strips.
_read_runner_from_file() {
	local _file="$1"
	[[ -r "$_file" ]] || return 0
	sed -nE 's|^      runner: (.+)$|\1|p' "$_file" | head -n 1
	return 0
}

# _needs_runner_sync <slug> <workflow_file>
# Returns 0 (true) when the on-disk runner does not match the repos.json
# `runner` field for this slug — i.e. the runner needs to be added, changed,
# or removed by `--apply`. Returns 1 (false) when they already match.
#
# This is the gap the comparator deliberately leaves: `_normalize_wf_for_compare`
# strips `runner:` lines before byte-comparison so a runner-only change does
# not flag a repo as DRIFTED/CALLER. Sync must detect runner drift separately
# (GH#21897); without this check, `--apply` skips repos that picked up a new
# `runner` field after the workflow was already in canonical caller shape.
_needs_runner_sync() {
	local _slug="$1"
	local _workflow_file="$2"
	local _expected _actual
	_expected=$(_read_runner_field "$_slug")
	_actual=$(_read_runner_from_file "$_workflow_file")
	[[ "$_expected" != "$_actual" ]]
}

# Returns 0 when the issue-first managed block needs an update, 1 when current,
# and 2 when the target/template is malformed or unavailable.
_contributing_policy_needs_sync() {
	local _repo_path="$1"
	local _template
	_template=$(_resolve_contributing_policy_template) || return 2
	[[ -f "$MANAGED_BLOCK_HELPER" ]] || return 2
	command -v python3 >/dev/null 2>&1 || return 2
	python3 "$MANAGED_BLOCK_HELPER" check \
		--file "$_repo_path/CONTRIBUTING.md" \
		--template "$_template" >/dev/null 2>&1
	local _check_rc=$?
	case "$_check_rc" in
	0) return 1 ;;
	1) return 0 ;;
	*) return 2 ;;
	esac
}

# Emits an empty line for eligible repositories or a stable skip reason.
_installation_skip_reason() {
	local _slug="$1"
	local _registry_flags
	_registry_flags=$(jq -r --arg slug "$_slug" '
		.initialized_repos[]?
		| select(.slug == $slug)
		| [(.local_only // false), (.contributed // false), (.role // "")]
		| @tsv
	' "$REPOS_JSON" 2>/dev/null | head -n 1)
	if [[ -z "$_registry_flags" ]]; then
		printf 'registry-entry-missing\n'
		return 0
	fi

	local _local_only _contributed _role
	IFS=$'\t' read -r _local_only _contributed _role <<<"$_registry_flags"
	if [[ "$_local_only" == "true" ]]; then
		printf 'local-only\n'
		return 0
	fi
	if [[ "$_contributed" == "true" || "$_role" == "contributor" ]]; then
		printf 'external-upstream\n'
		return 0
	fi
	if ! command -v gh >/dev/null 2>&1; then
		printf 'inaccessible\n'
		return 0
	fi

	local _repo_json
	_repo_json=$(gh api "repos/${_slug}" 2>/dev/null) || {
		printf 'inaccessible\n'
		return 0
	}
	if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$_repo_json"; then
		printf 'inaccessible\n'
		return 0
	fi
	if jq -e '.archived == true' >/dev/null 2>&1 <<<"$_repo_json"; then
		printf 'archived\n'
		return 0
	fi
	if jq -e '(.permissions.admin == true) or (.permissions.maintain == true)' \
		>/dev/null 2>&1 <<<"$_repo_json"; then
		printf '\n'
		return 0
	fi
	printf 'insufficient-permission\n'
	return 0
}

_emit_actionable_row() {
	local _slug="$1"
	local _path="$2"
	local _class="$3"
	local _workflow="$4"
	local _skip_reason=""
	if [[ "${_OPT_INSTALL_MISSING:-0}" -eq 1 ]]; then
		if [[ "$_class" == "$_CLASS_LOCAL_ONLY" ]]; then
			_skip_reason="local-only"
		else
			_skip_reason=$(_installation_skip_reason "$_slug")
		fi
	fi
	printf '%s\t%s\t%s\t%s\t%s\n' \
		"$_slug" "$_path" "$_class" "$_workflow" "$_skip_reason"
	return 0
}

# ─── Classification Ingestion ───────────────────────────────────────────────

# Invoke check-workflows-helper.sh --json and filter to actionable rows.
# Emits TSV: slug\tpath\tstatus\tworkflow\tinstall-skip-reason
# _list_actionable_repos <filter_slug> [filter_workflow]
_list_actionable_repos() {
	local _filter_slug="$1"
	local _filter_workflow="${2:-}"
	local _check_args=(--json)
	[[ -n "$_filter_slug" ]] && _check_args+=(--repo "$_filter_slug")
	[[ -n "$_filter_workflow" ]] && _check_args+=(--workflow "$_filter_workflow")

	# check-workflows-helper.sh exits 1 when actionable rows exist — that is
	# precisely when we have work to do. Capture output regardless of exit.
	local _json
	_json=$("$CHECK_HELPER" "${_check_args[@]}" 2>/dev/null || true)
	if [[ -z "$_json" ]]; then
		return 1
	fi

	# Step 1 — drift and migration rows are always actionable. NO-WORKFLOW and
	# LOCAL-ONLY rows enter only through the narrow --install-missing path.
	local _candidate_rows
	_candidate_rows=$(printf '%s\n' "$_json" | jq -r \
		--arg drifted "$_CLASS_DRIFTED" \
		--arg needs "$_CLASS_NEEDS_MIGRATION" \
		--arg missing "$_CLASS_NO_WORKFLOW" \
		--arg local "$_CLASS_LOCAL_ONLY" \
		--argjson install "${_OPT_INSTALL_MISSING:-0}" \
		'select(
			(.classification == $drifted)
			or (.classification == $needs)
			or (($install == 1) and (
				(.classification == $missing) or (.classification == $local)
			))
		)
		| [.slug, .path, .classification, (.workflow // "")] | @tsv' 2>/dev/null)
	local _row_slug _row_path _row_class _row_workflow
	while IFS=$'\t' read -r _row_slug _row_path _row_class _row_workflow; do
		[[ -z "$_row_slug" ]] && continue
		_emit_actionable_row "$_row_slug" "$_row_path" "$_row_class" "$_row_workflow"
	done <<<"$_candidate_rows"

	# Step 2 — CURRENT/CALLER rows whose `runner:` value drifted from
	# `repos.json` (GH#21897). The comparator strips `runner:` before byte-
	# matching so a runner add/change/remove never raises DRIFTED, and the
	# Step 1 filter would skip these repos forever. Post-filter through
	# `_needs_runner_sync` against the on-disk file and emit only the
	# subset where the runner actually needs to change.
	local _wf_file _needs_sync
	while IFS=$'\t' read -r _row_slug _row_path _row_class _row_workflow; do
		[[ -z "$_row_slug" ]] && continue
		# `.workflow` is the short name (e.g. "issue-sync"); reconstruct path.
		_wf_file="$_row_path/.github/workflows/${_row_workflow}.yml"
		_needs_sync=0
		_needs_runner_sync "$_row_slug" "$_wf_file" && _needs_sync=1
		if [[ "$_row_workflow" == "$LINKED_ISSUE_WORKFLOW_NAME" ]]; then
			_contributing_policy_needs_sync "$_row_path" && _needs_sync=1
			[[ "$?" -eq 2 ]] && _needs_sync=1
		fi
		if [[ "$_needs_sync" -eq 1 ]]; then
			_emit_actionable_row "$_row_slug" "$_row_path" "$_row_class" "$_row_workflow"
		fi
	done < <(printf '%s\n' "$_json" | jq -r \
		--arg current "$_CLASS_CURRENT_CALLER" \
		'select(.classification == $current)
			| [.slug, .path, .classification, (.workflow // "")] | @tsv' 2>/dev/null)

	return 0
}

# _classify_after_refresh <slug> <workflow> <worktree-path>
# Reuses check-workflows as the single classifier after apply refreshes a repo.
_classify_after_refresh() {
	local _slug="$1"
	local _workflow="$2"
	local _path="$3"
	local _json
	_json=$(AIDEVOPS_WORKFLOW_REPO_ROOT="$_path" \
		"$CHECK_HELPER" --json --repo "$_slug" --workflow "$_workflow" 2>/dev/null || true)
	if [[ -z "$_json" ]]; then
		return 1
	fi
	printf '%s\n' "$_json" | jq -r --arg slug "$_slug" \
		'select(.slug == $slug) | .classification' 2>/dev/null | head -n 1
	return 0
}

# ─── Message Formatters ─────────────────────────────────────────────────────
# Bash 3.2-safe multi-line body builders (no heredoc inside $()).

# _format_commit_body <status> <ref> <workflow_path> <sync-contributing>
# shellcheck disable=SC2016  # backticks are intentional markdown literals
_format_commit_body() {
	local _status="$1"
	local _ref="$2"
	local _workflow_path="$3"
	local _sync_contributing="$4"
	if [[ "$_sync_contributing" -eq 1 ]]; then
		printf 'Install the issue-first external contribution policy.\n\n'
		printf 'Files managed:\n'
		printf -- '- `%s`\n' "$_workflow_path"
		printf -- '- `CONTRIBUTING.md` issue-first pull request block\n\n'
		printf 'Classification before: %s\n' "$_status"
		printf 'Ref: %s\n' "$_ref"
		[[ -n "${_OPT_ISSUE:-}" ]] && printf 'Rollout task: GH#%s\n' "$_OPT_ISSUE"
		return 0
	fi
	printf 'Resync `%s` to the canonical aidevops caller template.\n\n' "$_workflow_path"
	printf 'Classification before: %s\n' "$_status"
	printf 'Ref: %s\n\n' "$_ref"
	printf 'This migrates/refreshes the workflow to the reusable-workflow pattern.\n'
	printf 'The caller now delegates all logic to the aidevops reusable workflow,\n'
	printf 'eliminating drift between this repo and the framework canonical version.\n\n'
	printf 'Generated by: `aidevops sync-workflows --apply` (see marcusquinn/aidevops#20649)\n'
	return 0
}

# _format_pr_body <status> <ref> <workflow_path> <sync-contributing>
# shellcheck disable=SC2016  # backticks are intentional markdown literals
_format_pr_body() {
	local _status="$1"
	local _ref="$2"
	local _workflow_path="$3"
	local _sync_contributing="$4"
	if [[ "$_sync_contributing" -eq 1 ]]; then
		printf '## Summary\n\n'
		printf -- '- Install `%s` to validate local issue references on external pull requests.\n' "$_workflow_path"
		printf -- '- Add or refresh the managed issue-first policy in `CONTRIBUTING.md`.\n\n'
		printf '## Why\n\n'
		printf 'Maintainers monitor the issue queue more consistently than unsolicited pull requests.\n'
		printf 'External contributors should create or find a local issue before opening a PR.\n\n'
		printf '## Security\n\n'
		printf 'The workflow consumes immutable event metadata only. It does not check out, source,\n'
		printf 'or execute pull-request head content.\n\n'
		printf '## Verification\n\n'
		printf -- '- External human PR without an accepted local issue reference: check fails.\n'
		printf -- '- Owner, member, collaborator, and bot PRs: documented exemptions apply.\n'
		printf -- '- Re-running the rollout produces no file changes.\n\n'
		printf '**Classification before**: `%s`  \n' "$_status"
		printf '**Ref**: `%s`\n' "$_ref"
		[[ -n "${_OPT_ISSUE:-}" ]] && printf '**Rollout task**: `GH#%s`\n' "$_OPT_ISSUE"
		return 0
	fi
	printf '## Summary\n\n'
	printf 'Resync `%s` to the canonical aidevops caller template\n' "$_workflow_path"
	printf '(reusable-workflow pattern, GH#20649 + GH#20727).\n\n'
	printf '**Classification before**: `%s`\n' "$_status"
	printf '**Ref**: `%s`\n\n' "$_ref"
	printf '## Why\n\n'
	printf 'The aidevops framework ships managed GitHub Actions workflows as reusable\n'
	printf 'workflows. Downstream repos carry ~45-line callers that delegate all logic\n'
	printf 'to the configured aidevops reusable workflow repository/ref.\n\n'
	printf 'This PR brings this repo in line with the canonical template, eliminating\n'
	printf 'drift and unblocking automatic updates when the framework evolves.\n\n'
	printf '## How to verify\n\n'
	printf 'After merge, trigger an event matching the workflow triggers. Framework\n'
	printf 'scripts are fetched at runtime via a secondary checkout — no\n'
	printf '`.agents/scripts/` files are needed in this repo.\n\n'
	printf '## Rollback\n\n'
	printf 'If the workflow breaks, revert this PR. The previous workflow is preserved\n'
	printf 'in git history at the parent commit.\n\n'
	printf 'Generated by: `aidevops sync-workflows --apply` (see marcusquinn/aidevops#20649).\n'
	return 0
}

_format_pr_title() {
	local _sync_contributing="$1"
	if [[ "$_sync_contributing" -eq 1 ]]; then
		if [[ -n "${_OPT_ISSUE:-}" ]]; then
			printf 'GH#%s: enforce issue-first external pull requests\n' "$_OPT_ISSUE"
		else
			printf 'chore: enforce issue-first external pull requests\n'
		fi
		return 0
	fi
	printf 'chore: resync framework workflow to aidevops canonical caller\n'
	return 0
}

_create_pr_body_file() {
	local _status="$1"
	local _ref="$2"
	local _workflow_path="$3"
	local _sync_contributing="$4"
	local _temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$_temp_root" || return 1
	local _body_file
	_body_file=$(mktemp "${_temp_root%/}/sync-workflows-pr.XXXXXX") || return 1
	if ! _format_pr_body "$_status" "$_ref" "$_workflow_path" \
		"$_sync_contributing" >"$_body_file"; then
		rm -f "$_body_file"
		return 1
	fi
	printf '%s\n' "$_body_file"
	return 0
}

# ─── Per-Repo Operation ─────────────────────────────────────────────────────

# _resolve_effective_ref <status> <workflow_path> <target_ref> <force_ref>
# Emits the ref to use for the sync (preserves pin for DRIFTED unless forced).
_resolve_effective_ref() {
	local _status="$1"
	local _workflow="$2"
	local _target_ref="$3"
	local _force_ref="$4"
	local _effective_ref="$_target_ref"
	if [[ "$_status" == "$_CLASS_DRIFTED" && "$_force_ref" -eq 0 ]]; then
		local _existing_pin
		_existing_pin=$(_extract_ref_pin "$_workflow")
		if [[ -n "$_existing_pin" ]]; then
			_effective_ref="$_existing_pin"
		fi
	fi
	printf '%s\n' "$_effective_ref"
	return 0
}

# _sync_dryrun_emit <slug> <status> <effective_ref> <workflow-relpath> <sync-contributing>
_sync_dryrun_emit() {
	local _slug="$1"
	local _status="$2"
	local _effective_ref="$3"
	local _workflow_relpath="${4:-.github/workflows/issue-sync.yml}"
	local _sync_contributing="${5:-0}"
	local _action
	if [[ "$_sync_contributing" -eq 1 ]]; then
		_action="install policy"
	else
		case "$_status" in
		"$_CLASS_DRIFTED") _action="refresh" ;;
		"$_CLASS_CURRENT_CALLER") _action="update runner" ;;
		*) _action="install" ;;
		esac
	fi
	local _targets="$_workflow_relpath"
	[[ "$_sync_contributing" -eq 1 ]] && _targets="${_targets} + CONTRIBUTING.md"
	printf '%s\t%s\t%s\t%s → %s at ref %s\n' \
		"$_slug" "$_status" "$_STATUS_PLANNED" "$_action" \
		"$_targets" "$_effective_ref"
	return 0
}

# _sync_preflight <slug> <path> <status>
# Validates linked-worktree identity and clean state.
# Returns 0 proceed; 1 fail; 2 skip. Sets _PREFLIGHT_DEFAULT_BRANCH and
# _PREFLIGHT_REMOTE on proceed.
_sync_preflight() {
	local _slug="$1"
	local _path="$2"
	local _status="$3"

	if [[ ! -d "$_path" ]]; then
		printf '%s\t%s\t%s\trepo directory missing: %s\n' "$_slug" "$_status" "$_STATUS_FAILED" "$_path"
		return 1
	fi
	if ! git -C "$_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		printf '%s\t%s\t%s\tnot a git repo: %s\n' "$_slug" "$_status" "$_STATUS_FAILED" "$_path"
		return 1
	fi
	if ! _is_linked_worktree "$_path"; then
		printf '%s\t%s\t%s\trefusing canonical checkout mutation: %s\n' \
			"$_slug" "$_status" "$_STATUS_FAILED" "$_path"
		return 1
	fi
	local _remote
	if ! _remote=$(_resolve_github_remote "$_path" "$_slug"); then
		printf '%s\t%s\t%s\tmatching GitHub remote unavailable\n' \
			"$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi
	local _default_branch
	_default_branch=$(git -C "$_path" symbolic-ref --short "refs/remotes/${_remote}/HEAD" 2>/dev/null || true)
	_default_branch="${_default_branch#"${_remote}"/}"
	[[ -z "$_default_branch" ]] && _default_branch="$_BRANCH_DEFAULT_NAME"
	if [[ -n "$(git -C "$_path" status --porcelain 2>/dev/null)" ]]; then
		printf '%s\t%s\t%s\tworking tree not clean; skipping\n' "$_slug" "$_status" "$_STATUS_SKIPPED"
		return 2
	fi
	_PREFLIGHT_DEFAULT_BRANCH="$_default_branch"
	_PREFLIGHT_REMOTE="$_remote"
	return 0
}

# _sync_refresh_checkout <slug> <path> <status> <remote> <default_branch> <sync-branch>
# Apply must classify and mutate the same refreshed snapshot. Fail closed when
# refresh is unavailable rather than continuing with stale local evidence.
_sync_refresh_checkout() {
	local _slug="$1"
	local _path="$2"
	local _status="$3"
	local _remote="$4"
	local _default_branch="$5"
	local _branch_name="$6"
	if ! git -C "$_path" fetch -q "$_remote" "$_default_branch" >/dev/null 2>&1; then
		printf '%s\t%s\t%s\tfetch failed; refusing stale classification\n' \
			"$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi
	local _current_branch
	local _default_ref
	_current_branch=$(git -C "$_path" symbolic-ref --short HEAD 2>/dev/null || printf 'DETACHED')
	_default_ref=$(_remote_default_ref "$_remote" "$_default_branch")
	if [[ "$_current_branch" != "$_branch_name" ]] && \
		! git -C "$_path" checkout -q -B "$_branch_name" "$_default_ref"; then
		printf '%s\t%s\t%s\tfailed to prepare sync branch\n' \
			"$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi
	return 0
}

# _sync_write_commit_push <slug> <path> <status> <branch> <remote>
#   <default_branch> <effective_ref> <content> <workflow-relpath>
#   <sync-contributing>
# Returns 2 for an explicit successful no-op; the caller must not open a PR.
_sync_write_commit_push() {
	local _slug="$1"
	local _path="$2"
	local _status="$3"
	local _branch_name="$4"
	local _remote="$5"
	local _default_branch="$6"
	local _effective_ref="$7"
	local _target_content="$8"
	local _workflow_relpath="${9:-.github/workflows/issue-sync.yml}"
	local _sync_contributing="${10:-0}"
	local _workflow="$_path/$_workflow_relpath"

	local _workflow_current=0
	if [[ -f "$_workflow" ]] && \
		diff -q <(printf '%s\n' "$_target_content") "$_workflow" >/dev/null 2>&1; then
		_workflow_current=1
	fi
	local _policy_current=1
	local _policy_template=""
	if [[ "$_sync_contributing" -eq 1 ]]; then
		_policy_template=$(_resolve_contributing_policy_template) || {
			printf '%s\t%s\t%s\tcontributing policy template unavailable\n' \
				"$_slug" "$_status" "$_STATUS_FAILED"
			return 1
		}
		python3 "$MANAGED_BLOCK_HELPER" check \
			--file "$_path/CONTRIBUTING.md" --template "$_policy_template" >/dev/null 2>&1
		local _policy_rc=$?
		case "$_policy_rc" in
		0) _policy_current=1 ;;
		1) _policy_current=0 ;;
		*)
			printf '%s\t%s\t%s\tCONTRIBUTING.md managed markers are malformed\n' \
				"$_slug" "$_status" "$_STATUS_FAILED"
			return 1
			;;
		esac
	fi
	if [[ "$_workflow_current" -eq 1 && "$_policy_current" -eq 1 ]]; then
		printf '%s\t%s\t%s\tworkflow and contributing policy already current after refresh\n' \
			"$_slug" "$_status" "$_STATUS_SKIPPED"
		return 2
	fi
	local _current_branch
	local _default_ref
	_current_branch=$(git -C "$_path" symbolic-ref --short HEAD 2>/dev/null || printf 'DETACHED')
	_default_ref=$(_remote_default_ref "$_remote" "$_default_branch")
	if [[ "$_current_branch" != "$_branch_name" ]] && \
		! git -C "$_path" checkout -q -B "$_branch_name" "$_default_ref"; then
		printf '%s\t%s\t%s\tbranch create/reset failed\n' "$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi
	mkdir -p "$_path/.github/workflows" || return 1
	if [[ "$_sync_contributing" -eq 1 && "$_policy_current" -eq 0 ]]; then
		if ! python3 "$MANAGED_BLOCK_HELPER" apply \
			--file "$_path/CONTRIBUTING.md" --template "$_policy_template" >/dev/null 2>&1; then
			printf '%s\t%s\t%s\tCONTRIBUTING.md managed block update failed\n' \
				"$_slug" "$_status" "$_STATUS_FAILED"
			return 1
		fi
	fi
	if [[ "$_workflow_current" -eq 0 ]]; then
		printf '%s\n' "$_target_content" >"$_workflow"
	fi
	local _stage_paths=("$_workflow_relpath")
	[[ "$_sync_contributing" -eq 1 ]] && _stage_paths+=("CONTRIBUTING.md")
	if ! git -C "$_path" add -- "${_stage_paths[@]}" >/dev/null 2>&1; then
		printf '%s\t%s\t%s\tgit staging failed\n' "$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi
	local _commit_subject="chore: resync framework workflow ($_status → CURRENT/CALLER)"
	if [[ "$_sync_contributing" -eq 1 ]]; then
		_commit_subject="chore: enforce issue-first external pull requests"
		[[ -n "${_OPT_ISSUE:-}" ]] && _commit_subject="GH#${_OPT_ISSUE}: enforce issue-first external pull requests"
	fi
	local _commit_body
	_commit_body=$(_format_commit_body \
		"$_status" "$_effective_ref" "$_workflow_relpath" "$_sync_contributing")
	if git -C "$_path" diff --cached --quiet; then
		git -C "$_path" checkout -q "$_default_branch" || true
		printf '%s\t%s\t%s\tno staged diff after render; push and PR skipped\n' \
			"$_slug" "$_status" "$_STATUS_SKIPPED"
		return 2
	fi
	if ! git -C "$_path" commit -q -m "$_commit_subject" -m "$_commit_body"; then
		printf '%s\t%s\t%s\tgit commit failed\n' "$_slug" "$_status" "$_STATUS_FAILED"
		# Return to default branch on failure so subsequent runs are clean.
		git -C "$_path" checkout -q "$_default_branch" || true
		return 1
	fi
	if ! git -C "$_path" push -u "$_remote" "$_branch_name" >/dev/null 2>&1; then
		printf '%s\t%s\t%s\tgit push failed\n' "$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi
	return 0
}

# _sync_open_pr <slug> <path> <status> <branch> <default_branch>
#   <effective_ref> <workflow-relpath> <sync-contributing>
_sync_open_pr() {
	local _slug="$1"
	local _path="$2"
	local _status="$3"
	local _branch_name="$4"
	local _default_branch="$5"
	local _effective_ref="$6"
	local _workflow_relpath="${7:-.github/workflows/issue-sync.yml}"
	local _sync_contributing="${8:-0}"

	if ! command -v gh_create_pr >/dev/null 2>&1; then
		printf '%s\t%s\t%s\tgh_create_pr unavailable — source shared-gh-wrappers.sh\n' \
			"$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi
	local _existing_pr
	_existing_pr=$(gh pr list --repo "$_slug" --head "$_branch_name" --state open \
		--json url --jq '.[0].url // empty' 2>/dev/null || true)
	if [[ -n "$_existing_pr" ]]; then
		printf '%s\t%s\t%s\tPR: %s\n' "$_slug" "$_status" "$_STATUS_APPLIED" "$_existing_pr"
		return 0
	fi
	local _pr_title
	_pr_title=$(_format_pr_title "$_sync_contributing")
	local _body_file
	_body_file=$(_create_pr_body_file \
		"$_status" "$_effective_ref" "$_workflow_relpath" "$_sync_contributing") || {
		printf '%s\t%s\t%s\tPR body-file creation failed\n' \
			"$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	}
	local _stderr_file
	_stderr_file=$(mktemp "${_body_file%/*}/sync-workflows-pr-stderr.XXXXXX") || {
		rm -f "$_body_file"
		printf '%s\t%s\t%s\tPR diagnostic-file creation failed\n' \
			"$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	}
	local _pr_url _pr_stderr _failure_detail
	if ! _pr_url=$(gh_create_pr \
		--repo "$_slug" \
		--title "$_pr_title" \
		--body-file "$_body_file" \
		--head "$_branch_name" \
		--base "$_default_branch" 2>"$_stderr_file"); then
		_pr_stderr=$(<"$_stderr_file")
		[[ -s "$_stderr_file" ]] && command cat "$_stderr_file" >&2
		_failure_detail=$(printf '%s %s' "$_pr_url" "$_pr_stderr" |
			tr '\t\r\n' '   ' |
			sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' |
			cut -c1-500)
		[[ -n "$_failure_detail" ]] || _failure_detail="no diagnostic output"
		rm -f "$_body_file" "$_stderr_file"
		printf '%s\t%s\t%s\tgh_create_pr failed: %s\n' \
			"$_slug" "$_status" "$_STATUS_FAILED" "$_failure_detail"
		return 1
	fi
	[[ -s "$_stderr_file" ]] && command cat "$_stderr_file" >&2
	_pr_url=$(printf '%s' "$_pr_url" |
		tr '\t\r\n' '   ' |
		sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
	rm -f "$_body_file" "$_stderr_file"
	if [[ -z "$_pr_url" ]]; then
		printf '%s\t%s\t%s\tgh_create_pr returned empty stdout\n' \
			"$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi
	printf '%s\t%s\t%s\tPR: %s\n' "$_slug" "$_status" "$_STATUS_APPLIED" "$_pr_url"
	return 0
}

# _render_sync_target <template> <target-repo> <effective-ref> <slug> <workflow-name>
_render_sync_target() {
	local _template="$1"
	local _target_repo="$2"
	local _effective_ref="$3"
	local _slug="$4"
	local _workflow_name="$5"
	local _content
	_content=$(_render_template_with_target \
		"$_template" "$_target_repo" "$_effective_ref" "$_workflow_name") || return 1
	local _runner_override
	_runner_override=$(_read_runner_field "$_slug")
	if [[ -n "$_runner_override" ]]; then
		_content=$(_inject_runner_in_content "$_content" "$_runner_override")
	fi
	printf '%s\n' "$_content"
	return 0
}

# Resolve whether the refreshed checkout still needs a write. Emits the
# effective pre-write classification on success, or a complete result row when
# returning 1 (failure) or 2 (successful skip).
_resolve_refreshed_sync_status() {
	local _slug="$1"
	local _path="$2"
	local _prior_status="$3"
	local _workflow="$4"
	local _refreshed_status="$5"
	local _sync_contributing="$6"
	case "$_refreshed_status" in
	"$_CLASS_DRIFTED" | "$_CLASS_NEEDS_MIGRATION")
		printf '%s\n' "$_refreshed_status"
		return 0
		;;
	"$_CLASS_NO_WORKFLOW")
		if [[ "${_OPT_INSTALL_MISSING:-0}" -eq 1 ]]; then
			printf '%s\n' "$_refreshed_status"
			return 0
		fi
		printf '%s\t%s\t%s\tmissing workflow requires --install-missing\n' \
			"$_slug" "$_prior_status" "$_STATUS_SKIPPED"
		return 2
		;;
	"$_CLASS_CURRENT_CALLER")
		local _needs_sync=0
		_needs_runner_sync "$_slug" "$_workflow" && _needs_sync=1
		if [[ "$_sync_contributing" -eq 1 ]]; then
			_contributing_policy_needs_sync "$_path"
			local _policy_check_rc=$?
			case "$_policy_check_rc" in
			0) _needs_sync=1 ;;
			1) ;;
			*)
				printf '%s\t%s\t%s\tCONTRIBUTING.md managed markers are malformed\n' \
					"$_slug" "$_prior_status" "$_STATUS_FAILED"
				return 1
				;;
			esac
		fi
		if [[ "$_needs_sync" -eq 1 ]]; then
			printf '%s\n' "$_refreshed_status"
			return 0
		fi
		printf '%s\t%s\t%s\trefreshed checkout is CURRENT/CALLER; no changes\n' \
			"$_slug" "$_prior_status" "$_STATUS_SKIPPED"
		return 2
		;;
	*)
		printf '%s\t%s\t%s\tpost-refresh classification is %s; no workflow write attempted\n' \
			"$_slug" "$_prior_status" "$_STATUS_SKIPPED" "$_refreshed_status"
		return 2
		;;
	esac
}

# _sync_one_repo <slug> <path> <status> <template_path> <target_repo> <target_ref> <force_ref> <branch_name> <apply> <workflow_relpath>
# Emits a single-line summary; returns 0 on success, 1 on failure.
# workflow_relpath — path relative to repo root e.g. .github/workflows/review-bot-gate.yml
_sync_one_repo() {
	local _slug="$1"
	local _path="$2"
	local _status="$3"
	local _template="$4"
	local _target_repo="$5"
	local _target_ref="$6"
	local _force_ref="$7"
	local _branch_name="$8"
	local _apply="$9"
	local _workflow_relpath="${10:-.github/workflows/issue-sync.yml}"

	local _workflow="$_path/$_workflow_relpath"
	local _workflow_name
	_workflow_name=$(basename "$_workflow_relpath" .yml)
	local _sync_contributing=0
	[[ "$_workflow_name" == "$LINKED_ISSUE_WORKFLOW_NAME" ]] && _sync_contributing=1
	if [[ "$_apply" -eq 0 ]]; then
		local _effective_ref
		_effective_ref=$(_resolve_effective_ref "$_status" "$_workflow" "$_target_ref" "$_force_ref")
		_sync_dryrun_emit \
			"$_slug" "$_status" "$_effective_ref" "$_workflow_relpath" "$_sync_contributing"
		return 0
	fi

	_PREFLIGHT_DEFAULT_BRANCH="" _PREFLIGHT_REMOTE=""
	local _pf_rc
	_sync_preflight "$_slug" "$_path" "$_status"
	_pf_rc=$?
	if [[ "$_pf_rc" -ne 0 ]]; then
		# 1=failed (already emitted), 2=skipped (already emitted as SKIPPED).
		[[ "$_pf_rc" -eq 2 ]] && return 0
		return 1
	fi
	local _default_branch="$_PREFLIGHT_DEFAULT_BRANCH" _remote="$_PREFLIGHT_REMOTE" _refresh_output
	if ! _refresh_output=$(_sync_refresh_checkout \
		"$_slug" "$_path" "$_status" "$_remote" "$_default_branch" "$_branch_name"); then
		printf '%s\n' "$_refresh_output"
		return 1
	fi

	local _refreshed_status
	if ! _refreshed_status=$(_classify_after_refresh "$_slug" "$_workflow_name" "$_path"); then
		printf '%s\t%s\t%s\tpost-refresh classification failed\n' \
			"$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi
	if [[ -z "$_refreshed_status" ]]; then
		printf '%s\t%s\t%s\tpost-refresh classification returned no row\n' \
			"$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi

	local _status_resolution _status_rc
	_status_resolution=$(_resolve_refreshed_sync_status \
		"$_slug" "$_path" "$_status" "$_workflow" \
		"$_refreshed_status" "$_sync_contributing")
	_status_rc=$?
	if [[ "$_status_rc" -eq 2 ]]; then
		printf '%s\n' "$_status_resolution"
		return 0
	fi
	if [[ "$_status_rc" -ne 0 ]]; then
		printf '%s\n' "$_status_resolution"
		return 1
	fi
	_status="$_status_resolution"

	local _effective_ref
	_effective_ref=$(_resolve_effective_ref "$_status" "$_workflow" "$_target_ref" "$_force_ref")
	local _target_content
	if ! _target_content=$(_render_sync_target "$_template" "$_target_repo" "$_effective_ref" "$_slug" "$_workflow_name"); then
		printf '%s\t%s\t%s\ttemplate render failed\n' "$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi

	# Rewrite branch filter to match downstream default branch (e.g. develop → develop).
	if [[ "$_default_branch" != "$_BRANCH_DEFAULT_NAME" ]]; then
		_target_content=$(_rewrite_content_branch_filter "$_target_content" "$_default_branch")
	fi

	local _write_output _write_rc
	_write_output=$(_sync_write_commit_push \
		"$_slug" "$_path" "$_status" "$_branch_name" \
		"$_remote" "$_default_branch" "$_effective_ref" "$_target_content" \
		"$_workflow_relpath" "$_sync_contributing")
	_write_rc=$?
	if [[ "$_write_rc" -eq 2 ]]; then
		printf '%s\n' "$_write_output"
		return 0
	fi
	if [[ "$_write_rc" -ne 0 ]]; then
		printf '%s\n' "$_write_output"
		return 1
	fi

	_sync_open_pr \
		"$_slug" "$_path" "$_status" "$_branch_name" \
		"$_default_branch" "$_effective_ref" "$_workflow_relpath" "$_sync_contributing"
	return $?
}

# ─── Main ───────────────────────────────────────────────────────────────────

# ─── Arg Parsing & Output ───────────────────────────────────────────────────

# _parse_args "$@"  → sets package-level _OPT_* variables.
_parse_args() {
	_OPT_APPLY=0
	_OPT_FILTER_SLUG=""
	_OPT_FILTER_WORKFLOW=""
	_OPT_INSTALL_MISSING=0
	_OPT_ISSUE=""
	_OPT_FORCE_REF=0
	_OPT_TARGET_REF=""
	_OPT_BRANCH_NAME=""
	_OPT_JSON=0
	while (($# > 0)); do
		local _opt="$1"
		case "$_opt" in
		--apply) _OPT_APPLY=1; shift ;;
		--repo) _OPT_FILTER_SLUG="${2:-}"; shift 2 || _die "--repo requires an argument" ;;
		--workflow) _OPT_FILTER_WORKFLOW="${2:-}"; shift 2 || _die "--workflow requires an argument" ;;
		--install-missing) _OPT_INSTALL_MISSING=1; shift ;;
		--issue)
			_OPT_ISSUE="${2:-}"
			[[ "$_OPT_ISSUE" =~ ^[0-9]+$ ]] || _die "--issue requires a numeric issue number"
			shift 2 ;;
		--force-ref) _OPT_FORCE_REF=1; shift ;;
		--ref)
			_OPT_TARGET_REF="${2:-}"
			[[ -z "$_OPT_TARGET_REF" ]] && _die "--ref requires an argument"
			[[ "$_OPT_TARGET_REF" != @* ]] && _OPT_TARGET_REF="@$_OPT_TARGET_REF"
			shift 2 ;;
		--branch) _OPT_BRANCH_NAME="${2:-}"; shift 2 || _die "--branch requires an argument" ;;
		--json) _OPT_JSON=1; shift ;;
		-h | --help) _usage; exit 0 ;;
		*) _die "unknown option: $_opt" ;;
		esac
	done
	if [[ "$_OPT_INSTALL_MISSING" -eq 1 && -z "$_OPT_FILTER_WORKFLOW" ]]; then
		_die "--install-missing requires an explicit --workflow filter"
	fi
	return 0
}

# _print_result_row <json> <target_ref> <branch> <result_tsv>
_print_result_row() {
	local _json="$1"
	local _target_ref="$2"
	local _branch_name="$3"
	local _result="$4"
	local _r_slug _r_status _r_outcome _r_detail
	IFS=$'\t' read -r _r_slug _r_status _r_outcome _r_detail <<<"$_result"
	if [[ "$_json" -eq 1 ]]; then
		jq -cn --arg slug "$_r_slug" --arg status "$_r_status" \
			--arg outcome "$_r_outcome" --arg detail "$_r_detail" \
			--arg ref "$_target_ref" --arg branch "$_branch_name" \
			'{slug:$slug, classification:$status, outcome:$outcome, detail:$detail, ref:$ref, branch:$branch}'
		return 0
	fi
	local _colour="$_C_BLUE"
	case "$_r_outcome" in
	"$_STATUS_APPLIED") _colour="$_C_GREEN" ;;
	"$_STATUS_FAILED") _colour="$_C_RED" ;;
	"$_STATUS_SKIPPED") _colour="$_C_YELLOW" ;;
	esac
	printf '  %-40s %-20s %s%-10s%s %s\n' \
		"$_r_slug" "$_r_status" "$_colour" "$_r_outcome" "$_C_NC" "$_r_detail"
	return 0
}

# _process_rows <tsv> → iterates, resolves per-workflow template, calls _sync_one_repo.
# TSV columns: slug\tpath\tstatus\tworkflow_name\tinstall_skip_reason
# Returns the number of failures (0 if all ok).
_process_rows() {
	local _tsv="$1"
	local _any_failed=0
	local _slug _path _status _workflow_name _install_skip_reason
	while IFS=$'\t' read -r _slug _path _status _workflow_name _install_skip_reason; do
		[[ -z "$_slug" ]] && continue
		# Never touch aidevops itself (defence in depth; Phase 1 also emits
		# CURRENT/SELF-CALLER).
		[[ "$_slug" == "marcusquinn/aidevops" ]] && continue
		if [[ -n "$_install_skip_reason" ]]; then
			local _skip_result="${_slug}"$'\t'"${_status}"$'\t'"${_STATUS_SKIPPED}"$'\t'"eligibility: ${_install_skip_reason}"
			_COUNT_SKIPPED=$((_COUNT_SKIPPED + 1))
			case "$_install_skip_reason" in
			local-only) _COUNT_SKIP_LOCAL=$((_COUNT_SKIP_LOCAL + 1)) ;;
			external-upstream) _COUNT_SKIP_UPSTREAM=$((_COUNT_SKIP_UPSTREAM + 1)) ;;
			archived) _COUNT_SKIP_ARCHIVED=$((_COUNT_SKIP_ARCHIVED + 1)) ;;
			inaccessible | registry-entry-missing) _COUNT_SKIP_INACCESSIBLE=$((_COUNT_SKIP_INACCESSIBLE + 1)) ;;
			insufficient-permission) _COUNT_SKIP_PERMISSION=$((_COUNT_SKIP_PERMISSION + 1)) ;;
			esac
			_print_result_row "$_OPT_JSON" "${_OPT_TARGET_REF:-@${_DEFAULT_WORKFLOW_REUSABLE_REF}}" \
				"$_OPT_BRANCH_NAME" "$_skip_result"
			continue
		fi
		if [[ "$_OPT_APPLY" -eq 1 ]]; then
			local _safe_path
			if ! _safe_path=$(_prepare_apply_worktree "$_slug" "$_path" "$_OPT_BRANCH_NAME"); then
				local _prepare_result="${_slug}"$'\t'"${_status}"$'\t'"${_STATUS_FAILED}"$'\t'"safe linked worktree preparation failed"
				_any_failed=1
				_print_result_row "$_OPT_JSON" "${_OPT_TARGET_REF:-@${_DEFAULT_WORKFLOW_REUSABLE_REF}}" \
					"$_OPT_BRANCH_NAME" "$_prepare_result"
				continue
			fi
			_path="$_safe_path"
		fi

		# Resolve the template for this workflow.
		# _workflow_name is the short name (e.g. "issue-sync" or "review-bot-gate").
		# Map it to the template filename.
		local _workflow_file="${_workflow_name}.yml"
		local _template_file="${_workflow_name}-caller.yml"
		local _workflow_relpath=".github/workflows/${_workflow_file}"
		local _template=""
		if ! _template=$(_resolve_canonical_template "$_template_file"); then
			_warn "$_slug: cannot resolve template for workflow '${_workflow_name}' — skipping"
			continue
		fi
		local _target_repo _target_ref
		_target_repo=$(_workflow_reusable_repo_for_slug "$_slug")
		if [[ -n "$_OPT_TARGET_REF" ]]; then
			_target_ref="${_OPT_TARGET_REF#@}"
		else
			_target_ref=$(_workflow_reusable_ref_for_slug "$_slug")
		fi

		local _result _effective_ref _target_ref_arg
		_target_ref_arg="@${_target_ref}"
		_effective_ref=$(_resolve_effective_ref \
			"$_status" "$_path/$_workflow_relpath" "$_target_ref_arg" "$_OPT_FORCE_REF")
		if [[ "$_target_repo" != "$_DEFAULT_WORKFLOW_REUSABLE_REPO" ]] && \
			_workflow_fetches_framework_helpers "$_workflow_name" && \
			! _mirror_supports_helper_provenance "$_target_repo" "$_workflow_name" "$_effective_ref"; then
			_result="${_slug}"$'\t'"${_status}"$'\t'"${_STATUS_FAILED}"$'\t'"configured mirror must be registered and updated at ${_effective_ref} before caller sync"
			_any_failed=1
			_print_result_row "$_OPT_JSON" "$_target_ref_arg" "$_OPT_BRANCH_NAME" "$_result"
			continue
		fi
		if _result=$(_sync_one_repo \
			"$_slug" "$_path" "$_status" "$_template" \
			"$_target_repo" "$_target_ref_arg" "$_OPT_FORCE_REF" "$_OPT_BRANCH_NAME" "$_OPT_APPLY" \
			"$_workflow_relpath"); then
			:
		else
			_any_failed=1
		fi

		case "$(printf '%s' "$_result" | awk -F'\t' '{print $3}')" in
		"$_STATUS_APPLIED") ((_COUNT_APPLIED++)) ;;
		"$_STATUS_PLANNED") ((_COUNT_PLANNED++)) ;;
		"$_STATUS_SKIPPED") ((_COUNT_SKIPPED++)) ;;
		esac
		_print_result_row "$_OPT_JSON" "$_target_ref_arg" "$_OPT_BRANCH_NAME" "$_result"
	done <<<"$_tsv"
	return "$_any_failed"
}

# _print_header_footer <phase: header|footer> <apply>
_print_header_footer() {
	local _phase="$1"
	local _apply="$2"
	if [[ "$_OPT_JSON" -eq 1 ]]; then
		return 0
	fi
	if [[ "$_phase" == "header" ]]; then
		printf '\n'
		printf '  %-40s %-20s %-10s %s\n' "REPO" "CLASSIFICATION" "ACTION" "DETAIL"
		printf '  %s\n' "──────────────────────────────────────────────────────────────────────────────────"
		return 0
	fi
	printf '\n'
	if [[ "$_apply" -eq 0 ]]; then
		_info "dry-run: $_COUNT_PLANNED planned, $_COUNT_SKIPPED skipped. Re-run with --apply to migrate."
	else
		_info "applied: $_COUNT_APPLIED; skipped: $_COUNT_SKIPPED."
	fi
	if [[ "$_OPT_INSTALL_MISSING" -eq 1 ]]; then
		_info "eligibility skips: local-only=$_COUNT_SKIP_LOCAL, external-upstream=$_COUNT_SKIP_UPSTREAM, archived=$_COUNT_SKIP_ARCHIVED, inaccessible=$_COUNT_SKIP_INACCESSIBLE, insufficient-permission=$_COUNT_SKIP_PERMISSION."
	fi
	printf '\n'
	return 0
}

main() {
	_parse_args "$@"

	# Preconditions.
	[[ -f "$REPOS_JSON" ]] || _die "repos.json not found at $REPOS_JSON — aidevops may not be initialised"
	command -v jq >/dev/null 2>&1 || _die "jq required — install via Homebrew/apt"
	[[ -x "$CHECK_HELPER" ]] || _die "check-workflows-helper.sh not found or not executable at $CHECK_HELPER"
	command -v python3 >/dev/null 2>&1 || _die "python3 required for managed CONTRIBUTING.md blocks"
	[[ -f "$MANAGED_BLOCK_HELPER" ]] || _die "managed Markdown block helper missing at $MANAGED_BLOCK_HELPER"
	_resolve_contributing_policy_template >/dev/null || \
		_die "issue-first CONTRIBUTING.md policy template is unavailable"

	if [[ -z "$_OPT_BRANCH_NAME" ]]; then
		_OPT_BRANCH_NAME="chore/workflow-sync-$(date +%Y%m%d)"
	fi

	local _tsv
	if ! _tsv=$(_list_actionable_repos "$_OPT_FILTER_SLUG" "$_OPT_FILTER_WORKFLOW"); then
		_die "check-workflows-helper.sh failed — cannot classify repos"
	fi
	if [[ -z "$_tsv" ]]; then
		_info "no actionable repos/workflows (all CURRENT or NO-WORKFLOW)."
		return 0
	fi

	_COUNT_APPLIED=0
	_COUNT_PLANNED=0
	_COUNT_SKIPPED=0
	_COUNT_SKIP_LOCAL=0
	_COUNT_SKIP_UPSTREAM=0
	_COUNT_SKIP_ARCHIVED=0
	_COUNT_SKIP_INACCESSIBLE=0
	_COUNT_SKIP_PERMISSION=0

	_print_header_footer "header" "$_OPT_APPLY"
	local _any_failed=0
	_process_rows "$_tsv" || _any_failed=1
	_print_header_footer "footer" "$_OPT_APPLY"

	return "$_any_failed"
}

main "$@"
