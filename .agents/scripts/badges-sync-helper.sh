#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# badges-sync-helper.sh — opt-in sync of README badge blocks, local repo
# metrics, and the managed refresh workflow across owned-org repos (t2975).
#
# Partner to badges-check-helper.sh (Phase 1, t2975). Reads classifications
# from the detector and, per owned-org repo, either:
#   - inject:  inserts/updates the canonical badge block in README.md
#   - metrics:  generates docs/metrics JSON/Markdown/SVG assets locally
#   - install: copies the repo metrics caller workflow into .github/workflows/
#
# Sync/install operations are restricted to owned-org repos
# (marcusquinn, essentials-com, wpallstars, or ~/.config/aidevops/badge-orgs.conf).
# contributor-role/contributed repos and non-owned orgs are skipped with a
# SKIPPED/EXTERNAL note.
#
# Default mode is --dry-run. Pass --apply to actually write, commit, push,
# and open a PR per repo.
#
# Design invariants:
#   - Never push directly to main. Always via PR.
#   - Skip repos with uncommitted changes.
#   - Skip repos that aren't on their default branch.
#   - Each repo gets its own commit + PR — no cross-repo atomicity.
#   - aidevops repo itself is never touched by install (loc-badge runs natively there).
#   - Idempotent: running twice produces no second diff.
#
# Usage:
#   badges-sync-helper.sh [--apply] [--repo OWNER/REPO] [--json]
#                         [--branch NAME] [--no-workflow]
#   badges-sync-helper.sh --help
#
# Options:
#   --apply         Actually perform the sync. Without this, only prints
#                   what would happen (dry-run is the default).
#   --repo SLUG     Limit to a single repo.
#   --json          Emit one JSON object per repo.
#   --branch NAME   Branch name for PRs (default: chore/badges-sync-YYYYMMDD).
#   --no-workflow   Skip loc-badge workflow installation; only sync README blocks.
#   -h, --help      Show this help.
#
# Exit codes:
#   0  no work needed OR all targets succeeded
#   1  one or more repos failed
#   2  config error

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
if [[ -f "$SELF_DIR/shared-constants.sh" ]]; then
	source "$SELF_DIR/shared-constants.sh"
fi

# shellcheck source=/dev/null
if [[ -f "$SELF_DIR/shared-gh-wrappers.sh" ]]; then
	source "$SELF_DIR/shared-gh-wrappers.sh"
else
	printf '[%s] WARN: shared-gh-wrappers.sh not found — PR creation will fail\n' \
		"$SCRIPT_NAME" >&2
fi

_C_GREEN=$'\033[0;32m'
_C_RED=$'\033[0;31m'
_C_YELLOW=$'\033[1;33m'
_C_BLUE=$'\033[0;34m'
_C_NC=$'\033[0m'

readonly REPOS_JSON="$HOME/.config/aidevops/repos.json"

# Resolve script paths — prefer deployed copies (executable) over repo checkout.
_resolve_helper() {
	local _name="$1"
	local _deployed="$HOME/.aidevops/agents/scripts/${_name}"
	local _local="${SELF_DIR}/${_name}"
	if [[ -x "$_deployed" ]]; then
		printf '%s\n' "$_deployed"
		return 0
	fi
	if [[ -f "$_local" ]]; then
		printf '%s\n' "$_local"
		return 0
	fi
	return 1
}

_CHECK_HELPER="$(  _resolve_helper "badges-check-helper.sh"  || printf '%s' "$SELF_DIR/badges-check-helper.sh")"
_BADGES_HELPER="$( _resolve_helper "readme-badges-helper.sh" || printf '%s' "$SELF_DIR/readme-badges-helper.sh")"
_METRICS_HELPER="$( _resolve_helper "repo-metrics-helper.sh" || printf '%s' "$SELF_DIR/repo-metrics-helper.sh")"
readonly _CHECK_HELPER _BADGES_HELPER _METRICS_HELPER

# ─── Owned-orgs allowlist ───────────────────────────────────────────────────

readonly _DEFAULT_OWNED_ORGS=("marcusquinn" "essentials-com" "wpallstars")

_load_owned_orgs() {
	local _conf="$HOME/.config/aidevops/badge-orgs.conf"
	if [[ -f "$_conf" ]]; then
		while IFS= read -r _org; do
			[[ -z "$_org" || "${_org:0:1}" == "#" ]] && continue
			printf '%s\n' "$_org"
		done <"$_conf"
		return 0
	fi
	local _o
	for _o in "${_DEFAULT_OWNED_ORGS[@]}"; do
		printf '%s\n' "$_o"
	done
	return 0
}

_is_owned_org() {
	local _org="$1"
	local _owned_orgs
	_owned_orgs=$(_load_owned_orgs)
	local _o
	while IFS= read -r _o; do
		[[ "$_o" == "$_org" ]] && return 0
	done <<<"$_owned_orgs"
	return 1
}

# ─── Helpers ────────────────────────────────────────────────────────────────

readonly _STATUS_SKIPPED="SKIPPED"
readonly _STATUS_PLANNED="PLANNED"
readonly _STATUS_APPLIED="APPLIED"
readonly _STATUS_FAILED="FAILED"

readonly _BRANCH_DEFAULT_NAME="main"

_die() {
	local _msg="$1"
	local _code="${2:-2}"
	printf '[%s] %sERROR%s: %s\n' "$SCRIPT_NAME" "$_C_RED" "$_C_NC" "$_msg" >&2
	exit "$_code"
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

_usage() {
	cat <<'EOF'

badges-sync-helper.sh — sync README badge blocks, repo metrics, and refresh workflow (t2975)

Reads classifications from badges-check-helper.sh and, per owned-org repo,
injects/updates the canonical badge block in README.md, generates committed
docs/metrics artifacts, and installs the repo metrics refresh workflow. Only
operates on owned-org repos.

Default is --dry-run. Pass --apply to write, commit, push, and open PRs.

Usage:
  badges-sync-helper.sh [--apply] [--repo OWNER/REPO] [--json]
                        [--branch NAME] [--no-workflow]
  badges-sync-helper.sh --help

Options:
  --apply       Actually perform the sync. Without this, only prints
                what would happen (dry-run is the default for safety).
  --repo SLUG   Limit to a single repo. Example: --repo owner/repo.
  --json        Emit one JSON object per repo describing outcome.
  --branch NAME Branch name prefix (default: chore/badges-sync-YYYYMMDD).
  --no-workflow Skip repo metrics workflow installation; only sync README blocks and local metrics.
  -h, --help    Show this help.

Exit codes:
  0  no work needed OR all targets succeeded
  1  one or more repos failed
  2  config error

EOF
	return 0
}

# ─── Template resolution ────────────────────────────────────────────────────

_resolve_loc_badge_template() {
	local _candidates=(
		"$HOME/.aidevops/agents/templates/workflows/loc-badge-caller.yml"
		"$SELF_DIR/../templates/workflows/loc-badge-caller.yml"
	)
	local _p
	for _p in "${_candidates[@]}"; do
		if [[ -f "$_p" ]]; then
			printf '%s\n' "$_p"
			return 0
		fi
	done
	return 1
}

# ─── Preflight ──────────────────────────────────────────────────────────────

# _sync_preflight <slug> <path>
# Validates clean-tree and on-default-branch; sets _PREFLIGHT_DEFAULT_BRANCH.
# Returns 0=proceed, 1=fail, 2=skip.
_sync_preflight() {
	local _slug="$1"
	local _path="$2"

	if [[ ! -d "$_path" ]]; then
		printf '%s\t%s\trepo directory missing: %s\n' "$_slug" "$_STATUS_FAILED" "$_path"
		return 1
	fi
	if [[ ! -d "$_path/.git" && ! -f "$_path/.git" ]]; then
		printf '%s\t%s\tnot a git repo: %s\n' "$_slug" "$_STATUS_FAILED" "$_path"
		return 1
	fi
	local _default_branch
	_default_branch=$(git -C "$_path" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
	[[ -z "$_default_branch" ]] && _default_branch="$_BRANCH_DEFAULT_NAME"
	if ! git -C "$_path" diff-index --quiet HEAD -- 2>/dev/null; then
		printf '%s\t%s\tworking tree not clean; skipping\n' "$_slug" "$_STATUS_SKIPPED"
		return 2
	fi
	local _current_branch
	_current_branch=$(git -C "$_path" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
	if [[ "$_current_branch" != "$_default_branch" ]]; then
		printf '%s\t%s\ton %s, expected %s; skipping\n' \
			"$_slug" "$_STATUS_SKIPPED" "$_current_branch" "$_default_branch"
		return 2
	fi
	_PREFLIGHT_DEFAULT_BRANCH="$_default_branch"
	return 0
}

# ─── README sync ────────────────────────────────────────────────────────────

# _sync_readme <slug> <path> <apply> <branch_name> <default_branch>
# Injects/updates the canonical badge block in README.md.
# Emits: slug\tstatus\tdetail
_sync_readme() {
	local _slug="$1"
	local _path="$2"
	local _apply="$3"
	local _branch_name="$4"
	local _default_branch="$5"
	local _readme="$_path/README.md"

	if [[ ! -f "$_readme" ]]; then
		printf '%s\t%s\tno README.md found\n' "$_slug" "$_STATUS_SKIPPED"
		return 0
	fi

	if [[ "$_apply" -eq 0 ]]; then
		# Check if badge block already matches
		local _check_rc=0
		bash "$_BADGES_HELPER" check "$_readme" "$_slug" >/dev/null 2>&1 || _check_rc=$?
		if [[ "$_check_rc" -eq 0 ]]; then
			printf '%s\t%s\tbadge block current\n' "$_slug" "$_STATUS_SKIPPED"
		else
			printf '%s\t%s\tinject → README.md at ref @main\n' "$_slug" "$_STATUS_PLANNED"
		fi
		return 0
	fi

	# Apply: inject badge block
	if ! git -C "$_path" pull --ff-only origin "$_default_branch" >/dev/null 2>&1; then
		_warn "$_slug: pull --ff-only failed"
	fi
	if ! git -C "$_path" checkout -q -B "$_branch_name" "$_default_branch"; then
		printf '%s\t%s\tbranch create/reset failed\n' "$_slug" "$_STATUS_FAILED"
		return 1
	fi

	if ! bash "$_BADGES_HELPER" inject "$_readme" "$_slug" 2>/dev/null; then
		printf '%s\t%s\treadme-badges-helper.sh inject failed\n' "$_slug" "$_STATUS_FAILED"
		git -C "$_path" checkout -q "$_default_branch" || true
		return 1
	fi

	if [[ -f "$_METRICS_HELPER" ]]; then
		if ! bash "$_METRICS_HELPER" generate \
			--output-dir "$_path/docs/metrics" \
			--badge-dir "$_path/docs/metrics/badges" \
			--legacy-badge-dir "$_path/.github/badges" \
			"$_path" >/dev/null 2>&1; then
			printf '%s\t%s\trepo metrics generation failed\n' "$_slug" "$_STATUS_FAILED"
			git -C "$_path" checkout -q "$_default_branch" || true
			return 1
		fi
	fi

	local _changes
	_changes=$(git -C "$_path" status --porcelain -- "README.md" "docs/metrics" ".github/badges" 2>/dev/null || true)
	if [[ -z "$_changes" ]]; then
		git -C "$_path" checkout -q "$_default_branch" || true
		printf '%s\t%s\tbadge block and repo metrics already current\n' "$_slug" "$_STATUS_SKIPPED"
		return 0
	fi

	git -C "$_path" add "README.md" "docs/metrics" ".github/badges" >/dev/null 2>&1
	if ! git -C "$_path" diff --cached --quiet; then
		local _commit_msg="chore: refresh aidevops README badges and repo metrics"
		if ! git -C "$_path" commit -q -m "$_commit_msg"; then
			printf '%s\t%s\tgit commit failed\n' "$_slug" "$_STATUS_FAILED"
			git -C "$_path" checkout -q "$_default_branch" || true
			return 1
		fi
	fi

	if ! git -C "$_path" push -u origin "$_branch_name" >/dev/null 2>&1; then
		printf '%s\t%s\tgit push failed\n' "$_slug" "$_STATUS_FAILED"
		return 1
	fi

	# Open PR
	_open_pr "$_slug" "$_path" "$_branch_name" "$_default_branch" "badge block injection"
	return $?
}

# ─── Workflow install ────────────────────────────────────────────────────────

# _install_workflow <slug> <path> <apply> <branch_name> <default_branch>
# Installs the repo metrics caller into .github/workflows/loc-badge.yml.
_install_workflow() {
	local _slug="$1"
	local _path="$2"
	local _apply="$3"
	local _branch_name="$4"
	local _default_branch="$5"
	local _target="$_path/.github/workflows/loc-badge.yml"

	local _template
	if ! _template=$(_resolve_loc_badge_template); then
		printf '%s\t%s\trepo metrics workflow template not found\n' "$_slug" "$_STATUS_SKIPPED"
		return 0
	fi

	# Already installed check
	if [[ -f "$_target" ]]; then
		printf '%s\t%s\tloc-badge.yml already installed\n' "$_slug" "$_STATUS_SKIPPED"
		return 0
	fi

	if [[ "$_apply" -eq 0 ]]; then
		printf '%s\t%s\tinstall → .github/workflows/loc-badge.yml (repo metrics refresh)\n' "$_slug" "$_STATUS_PLANNED"
		return 0
	fi

	if ! git -C "$_path" pull --ff-only origin "$_default_branch" >/dev/null 2>&1; then
		_warn "$_slug: pull --ff-only failed"
	fi
	if ! git -C "$_path" checkout -q -B "$_branch_name" "$_default_branch"; then
		printf '%s\t%s\tbranch create/reset failed\n' "$_slug" "$_STATUS_FAILED"
		return 1
	fi

	mkdir -p "$_path/.github/workflows"
	if ! cp "$_template" "$_target"; then
		printf '%s\t%s\tcp template failed\n' "$_slug" "$_STATUS_FAILED"
		git -C "$_path" checkout -q "$_default_branch" || true
		return 1
	fi

	git -C "$_path" add ".github/workflows/loc-badge.yml" >/dev/null 2>&1
	if ! git -C "$_path" diff --cached --quiet; then
		local _commit_msg="chore: install repo metrics refresh workflow (via aidevops badges sync)"
		if ! git -C "$_path" commit -q -m "$_commit_msg"; then
			printf '%s\t%s\tgit commit failed\n' "$_slug" "$_STATUS_FAILED"
			git -C "$_path" checkout -q "$_default_branch" || true
			return 1
		fi
	fi

	if ! git -C "$_path" push -u origin "$_branch_name" >/dev/null 2>&1; then
		printf '%s\t%s\tgit push failed\n' "$_slug" "$_STATUS_FAILED"
		return 1
	fi

	_open_pr "$_slug" "$_path" "$_branch_name" "$_default_branch" "repo metrics workflow install"
	return $?
}

# ─── PR creation ────────────────────────────────────────────────────────────

# _open_pr <slug> <path> <branch> <default_branch> <description>
_open_pr() {
	local _slug="$1"
	local _path="$2"
	local _branch_name="$3"
	local _default_branch="$4"
	local _description="$5"

	if ! command -v gh_create_pr >/dev/null 2>&1; then
		printf '%s\t%s\tgh_create_pr unavailable — source shared-gh-wrappers.sh\n' \
			"$_slug" "$_STATUS_FAILED"
		return 1
	fi

	local _pr_title="chore: aidevops badge sync — ${_description}"
	local _pr_body
	_pr_body=$(printf '%s\n' \
		"## Summary" \
		"" \
		"Sync README badge block, local repo metrics, and/or install the refresh workflow." \
		"" \
		"**Change:** ${_description}" \
		"" \
		"## Why" \
		"" \
		"The aidevops framework provides a canonical badge block for README files" \
		"and dependency-light local repository metrics. This PR brings this repo in line with" \
		"the canonical template." \
		"" \
		"## How to verify" \
		"" \
		"After merge: check README.md contains \`<!-- aidevops:badges:start -->\` block." \
		"Check \`docs/metrics/repo-metrics.json\` and \`docs/metrics/badges/*.svg\` exist." \
		"" \
		"Generated by: \`aidevops badges sync --apply\` (canonical badge sync).")

	local _pr_url
	if ! _pr_url=$(gh_create_pr \
		--repo "$_slug" \
		--title "$_pr_title" \
		--body "$_pr_body" \
		--head "$_branch_name" \
		--base "$_default_branch" 2>&1); then
		printf '%s\t%s\tgh_create_pr failed: %s\n' "$_slug" "$_STATUS_FAILED" "$_pr_url"
		return 1
	fi
	git -C "$_path" checkout "$_default_branch" >/dev/null 2>&1 || true
	printf '%s\t%s\tPR: %s\n' "$_slug" "$_STATUS_APPLIED" "$_pr_url"
	return 0
}

# ─── Iteration ──────────────────────────────────────────────────────────────

_repo_is_contributor() {
	local _slug="$1"
	[[ -f "$REPOS_JSON" ]] || return 1
	jq -e --arg slug "$_slug" \
		'first(.initialized_repos[]? | select(.slug == $slug)) | .role == "contributor"' \
		"$REPOS_JSON" >/dev/null 2>&1
	return $?
}

# _list_actionable_repos <filter_slug>
# Emits TSV: slug\tpath\tstatus for repos needing sync.
_list_actionable_repos() {
	local _filter_slug="$1"
	local _check_args=(--json)
	[[ -n "$_filter_slug" ]] && _check_args+=(--repo "$_filter_slug")

	local _json
	_json=$("$_CHECK_HELPER" "${_check_args[@]}" 2>/dev/null || true)
	if [[ -z "$_json" ]]; then
		return 1
	fi

		# Filter to DRIFTED, METRICS-MISSING, and NO-BLOCK (actionable); carry slug, path, status
	printf '%s\n' "$_json" | jq -r \
		'select((.classification == "DRIFTED") or (.classification == "METRICS-MISSING") or (.classification == "NO-BLOCK"))
		| [.slug, .path, .classification] | @tsv' 2>/dev/null
	return 0
}

# _process_rows <apply> <branch_name> <no_workflow> <json> <workflow_only>
# Reads TSV rows from stdin (slug\tpath\tstatus), processes each.
_process_rows() {
	local _apply="$1"
	local _branch_name="$2"
	local _no_workflow="$3"
	local _json_out="$4"
	local _workflow_only_arg="${5:-0}"
	local _any_failed=0

	local _slug _path _status
	while IFS=$'\t' read -r _slug _path _status; do
		[[ -z "$_slug" ]] && continue
		# Never touch aidevops itself
		[[ "$_slug" == "marcusquinn/aidevops" ]] && continue
		if _repo_is_contributor "$_slug"; then
			local _result="${_slug}	${_STATUS_SKIPPED}	contributor role — sync is read-only"
			_print_result_row "$_json_out" "$_result"
			_COUNT_SKIPPED=$((_COUNT_SKIPPED + 1))
			continue
		fi

		# Enforce owned-org filter at write time
		local _org="${_slug%%/*}"
		if ! _is_owned_org "$_org"; then
			local _result="${_slug}	${_STATUS_SKIPPED}	external org — sync restricted to owned orgs"
			_print_result_row "$_json_out" "$_result"
			_COUNT_SKIPPED=$((_COUNT_SKIPPED + 1))
			continue
		fi

		# Resolve path
		local _rpath="${_path/#\~/$HOME}"

		# Preflight
		_PREFLIGHT_DEFAULT_BRANCH=""
		local _pf_rc=0
		local _pf_out
		_pf_out=$(_sync_preflight "$_slug" "$_rpath") || _pf_rc=$?

		if [[ "$_pf_rc" -eq 1 ]]; then
			_print_result_row "$_json_out" "$_pf_out"
			_any_failed=1
			_COUNT_FAILED=$((_COUNT_FAILED + 1))
			continue
		fi
		if [[ "$_pf_rc" -eq 2 ]]; then
			_print_result_row "$_json_out" "$_pf_out"
			_COUNT_SKIPPED=$((_COUNT_SKIPPED + 1))
			continue
		fi
		local _default_branch="$_PREFLIGHT_DEFAULT_BRANCH"

		# Sync README badge block (skip when --workflow-only)
		local _workflow_only="$_workflow_only_arg"
		if [[ "$_workflow_only" -eq 0 ]]; then
			local _readme_result
			_readme_result=$(_sync_readme "$_slug" "$_rpath" "$_apply" "$_branch_name" "$_default_branch")
			_print_result_row "$_json_out" "$_readme_result"
			local _readme_outcome
			_readme_outcome=$(printf '%s' "$_readme_result" | awk -F'\t' '{print $2}')
			case "$_readme_outcome" in
			"$_STATUS_APPLIED") _COUNT_APPLIED=$((_COUNT_APPLIED + 1)) ;;
			"$_STATUS_PLANNED") _COUNT_PLANNED=$((_COUNT_PLANNED + 1)) ;;
			"$_STATUS_SKIPPED") _COUNT_SKIPPED=$((_COUNT_SKIPPED + 1)) ;;
			"$_STATUS_FAILED") _any_failed=1; _COUNT_FAILED=$((_COUNT_FAILED + 1)) ;;
			esac
		fi

		# Install repo metrics workflow if not suppressed
		if [[ "$_no_workflow" -eq 0 ]]; then
			local _wf_result
			_wf_result=$(_install_workflow "$_slug" "$_rpath" "$_apply" "$_branch_name" "$_default_branch")
			_print_result_row "$_json_out" "$_wf_result"
			local _wf_outcome
			_wf_outcome=$(printf '%s' "$_wf_result" | awk -F'\t' '{print $2}')
			case "$_wf_outcome" in
			"$_STATUS_APPLIED") _COUNT_APPLIED=$((_COUNT_APPLIED + 1)) ;;
			"$_STATUS_PLANNED") _COUNT_PLANNED=$((_COUNT_PLANNED + 1)) ;;
			"$_STATUS_SKIPPED") _COUNT_SKIPPED=$((_COUNT_SKIPPED + 1)) ;;
			"$_STATUS_FAILED") _any_failed=1; _COUNT_FAILED=$((_COUNT_FAILED + 1)) ;;
			esac
		fi
	done

	return "$_any_failed"
}

# _print_result_row <json_out> <result_tsv>
_print_result_row() {
	local _json_out="$1"
	local _result="$2"
	local _r_slug _r_outcome _r_detail
	IFS=$'\t' read -r _r_slug _r_outcome _r_detail <<<"$_result"
	if [[ "$_json_out" -eq 1 ]]; then
		jq -cn --arg slug "$_r_slug" \
			--arg outcome "$_r_outcome" --arg detail "$_r_detail" \
			'{slug:$slug, outcome:$outcome, detail:$detail}'
		return 0
	fi
	local _colour="$_C_BLUE"
	case "$_r_outcome" in
	"$_STATUS_APPLIED") _colour="$_C_GREEN" ;;
	"$_STATUS_FAILED") _colour="$_C_RED" ;;
	"$_STATUS_SKIPPED") _colour="$_C_YELLOW" ;;
	esac
	printf '  %-40s %s%-10s%s %s\n' \
		"$_r_slug" "$_colour" "$_r_outcome" "$_C_NC" "$_r_detail"
	return 0
}

# ─── Arg parsing ────────────────────────────────────────────────────────────

_parse_args() {
	_OPT_APPLY=0
	_OPT_FILTER_SLUG=""
	_OPT_JSON=0
	_OPT_BRANCH_NAME=""
	_OPT_NO_WORKFLOW=0
	_OPT_WORKFLOW_ONLY=0
	while (($# > 0)); do
		local _opt="$1"
		case "$_opt" in
		--apply) _OPT_APPLY=1; shift ;;
		--repo) _OPT_FILTER_SLUG="${2:-}"; shift 2 || _die "--repo requires an argument" ;;
		--json) _OPT_JSON=1; shift ;;
		--branch) _OPT_BRANCH_NAME="${2:-}"; shift 2 || _die "--branch requires an argument" ;;
		--no-workflow) _OPT_NO_WORKFLOW=1; shift ;;
		--workflow-only) _OPT_WORKFLOW_ONLY=1; shift ;;
		-h | --help) _usage; exit 0 ;;
		*) _die "unknown option: $_opt" ;;
		esac
	done
	return 0
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
	# Handle --help / -h early before _parse_args to ensure exit fires in main process.
	local _a
	for _a in "$@"; do
		case "$_a" in
		-h | --help) _usage; exit 0 ;;
		esac
	done

	_parse_args "$@"

	[[ -f "$REPOS_JSON" ]] || _die "repos.json not found at $REPOS_JSON — aidevops may not be initialised"
	command -v jq >/dev/null 2>&1 || _die "jq required — install via Homebrew/apt"
	[[ -f "$_CHECK_HELPER" ]] || _die "badges-check-helper.sh not found at $_CHECK_HELPER — run: aidevops update"
	[[ -f "$_BADGES_HELPER" ]] || _die "readme-badges-helper.sh not found at $_BADGES_HELPER — run: aidevops update"

	if [[ -z "$_OPT_BRANCH_NAME" ]]; then
		_OPT_BRANCH_NAME="chore/badges-sync-$(date +%Y%m%d)"
	fi

	local _tsv
	if ! _tsv=$(_list_actionable_repos "$_OPT_FILTER_SLUG"); then
		_info "no actionable repos (all CURRENT or not classified)."
		return 0
	fi
	if [[ -z "$_tsv" ]]; then
		_info "no actionable repos (all badge blocks current)."
		return 0
	fi

	_COUNT_APPLIED=0
	_COUNT_PLANNED=0
	_COUNT_SKIPPED=0
	_COUNT_FAILED=0

	if [[ "$_OPT_JSON" -eq 0 ]]; then
		printf '\n'
		printf '  %-40s %-10s %s\n' "REPO" "ACTION" "DETAIL"
		printf '  %s\n' "──────────────────────────────────────────────────────────────────"
	fi

	local _any_failed=0
	while IFS=$'\t' read -r _row_slug _row_path _row_status; do
		printf '%s\t%s\t%s\n' "$_row_slug" "$_row_path" "$_row_status"
	done <<<"$_tsv" | _process_rows "$_OPT_APPLY" "$_OPT_BRANCH_NAME" "$_OPT_NO_WORKFLOW" "$_OPT_JSON" "$_OPT_WORKFLOW_ONLY" || _any_failed=1

	if [[ "$_OPT_JSON" -eq 0 ]]; then
		printf '\n'
		if [[ "$_OPT_APPLY" -eq 0 ]]; then
			_info "dry-run: $_COUNT_PLANNED planned, $_COUNT_SKIPPED skipped, $_COUNT_FAILED failed. Re-run with --apply to sync."
		else
			_info "applied: $_COUNT_APPLIED; skipped: $_COUNT_SKIPPED; failed: $_COUNT_FAILED."
		fi
		printf '\n'
	fi

	return "$_any_failed"
}

main "$@"
