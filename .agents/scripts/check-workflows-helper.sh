#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# check-workflows-helper.sh — detect framework workflow drift across registered repos (t2778, GH#20648)
#
# Compares each registered repo's managed framework workflows against the
# canonical caller templates in `.agents/templates/workflows/`. Currently
# managed workflows:
#   - issue-sync.yml         (template: issue-sync-caller.yml)
#   - review-bot-gate.yml    (template: review-bot-gate-caller.yml, GH#20727)
#   - maintainer-gate.yml    (template: maintainer-gate-caller.yml, GH#21154)
#   - linked-issue-check.yml (template: linked-issue-check-caller.yml, GH#28844)
#
# Classifies each (repo × workflow) as:
#
#   CURRENT/CALLER      — byte-identical to canonical (up to @ref pin variance)
#   * + LEGACY_ARTIFACTS — known superseded framework files remain downstream
#   CURRENT/SELF-CALLER — aidevops itself: uses `./.github/workflows/...` instead of remote ref
#   DRIFTED/CALLER      — uses the reusable workflow but caller YAML has diverged
#   NEEDS-MIGRATION     — legacy full-copy workflow, no `uses:` → should adopt caller pattern
#   NO-WORKFLOW         — workflow file not present (repo hasn't adopted this workflow)
#   LOCAL-ONLY          — repo has `local_only: true`, no remote to check
#   NO-TEMPLATE         — canonical template missing; helper cannot classify
#
# Usage:
#   check-workflows-helper.sh [--repo OWNER/REPO] [--workflow NAME] [--json] [--verbose]
#   check-workflows-helper.sh --help
#
# Options:
#   --repo OWNER/REPO   Check only the named slug (default: all registered)
#   --workflow NAME     Check only the named managed workflow.
#   --json              Machine-readable output (one JSON object per repo × workflow)
#   --verbose           Show diff summary for DRIFTED/CALLER entries
#   -h, --help          Show usage and exit 0
#
# Exit codes:
#   0  — all checked repos are CURRENT/CALLER, NO-WORKFLOW, or LOCAL-ONLY
#   1  — one or more repos are drifted, need migration, or retain legacy artifacts
#   2  — configuration or IO error (repos.json missing, template missing, jq unavailable)
#
# Why this exists:
#   Before the reusable-workflow architecture (t2770), every aidevops-enabled repo
#   carried a full copy of issue-sync.yml (~1300 lines) and the `.agents/scripts/`
#   helpers those workflows depended on. Fixes landed upstream never propagated.
#   Three known-drifted repos surfaced GH#20637 before this gap was closed.
#
#   After t2770, downstream repos ship a ~45-line caller that points at the
#   aidevops reusable workflow. This helper detects which repos still use the
#   legacy full-copy pattern (NEEDS-MIGRATION) and which caller YAMLs have
#   diverged from the canonical template (DRIFTED/CALLER).
#
#   GH#20727 extended the known-workflow set to include review-bot-gate.yml,
#   which had a SHA-pinned helper checkout that silently drifted after helper
#   changes (the Option A' settlement fix in PR #20572 never reached downstream
#   repos pinned to 73b664a).
#
#   Phase 2 (`aidevops sync-workflows --apply`) will migrate or refresh callers
#   based on this helper's classification.

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null) || SELF_DIR=""
REPO_ROOT=""
if [[ -n "$SELF_DIR" ]]; then
	REPO_ROOT=$(cd "$SELF_DIR/../.." && pwd 2>/dev/null) || REPO_ROOT=""
fi

# ─── Known managed workflows ────────────────────────────────────────────────
#
# Each entry is a colon-separated tuple:
#   workflow_file:reusable_file:template_file
#
# workflow_file   — the filename under .github/workflows/ in each repo
# reusable_file  — the reusable workflow filename in marcusquinn/aidevops
# template_file  — the canonical caller template filename under .agents/templates/workflows/
#
# Add new reusable-workflow migrations here. The helper loops over this list
# for every repo and classifies each (repo × workflow) independently.
#
# GH#20727: review-bot-gate added.
# GH#21154: maintainer-gate added (layer-1 defense-in-depth propagation).
# GH#28844: linked-issue-check added (external contribution visibility).
readonly _KNOWN_WORKFLOWS=(
	"issue-sync.yml:issue-sync-reusable.yml:issue-sync-caller.yml"
	"review-bot-gate.yml:review-bot-gate-reusable.yml:review-bot-gate-caller.yml"
	"maintainer-gate.yml:maintainer-gate-reusable.yml:maintainer-gate-caller.yml"
	"loc-badge.yml:loc-badge-reusable.yml:loc-badge-caller.yml"
	"linked-issue-check.yml:linked-issue-check-reusable.yml:linked-issue-check-caller.yml"
)

# Versioned inventory of framework-owned paths superseded by reusable callers.
# Detection is warning-only: modified or repository-specific files are never
# removed automatically.
_resolve_legacy_artifact_manifest() {
	local _deployed="${HOME:-}/.aidevops/agents/configs/workflow-legacy-artifacts.tsv"
	local _repo_local="$SELF_DIR/../configs/workflow-legacy-artifacts.tsv"
	if [[ -f "$_deployed" ]]; then
		printf '%s\n' "$_deployed"
		return 0
	fi
	if [[ -f "$_repo_local" ]]; then
		printf '%s\n' "$_repo_local"
		return 0
	fi
	return 1
}

# _legacy_artifacts_for_repo <repo-path> <workflow-name>
# Emits comma-separated repository-relative paths from the manifest that exist.
_legacy_artifacts_for_repo() {
	local _path="$1"
	local _workflow_name="$2"
	local _manifest=""
	_manifest=$(_resolve_legacy_artifact_manifest) || return 0
	local _manifest_workflow _artifact_path _superseded_by _introduced_in
	local _found=""
	while IFS=$'\t' read -r _manifest_workflow _artifact_path _superseded_by _introduced_in ||
		[[ -n "$_manifest_workflow" ]]; do
		[[ -z "$_manifest_workflow" || "$_manifest_workflow" == \#* ]] && continue
		[[ "$_manifest_workflow" != "$_workflow_name" ]] && continue
		[[ -f "$_path/$_artifact_path" ]] || continue
		if [[ -n "$_found" ]]; then
			_found="${_found}, ${_artifact_path}"
		else
			_found="$_artifact_path"
		fi
	done <"$_manifest"
	printf '%s\n' "$_found"
	return 0
}

# ─── Path resolution ────────────────────────────────────────────────────────

# Canonical template — prefer deployed copy, fall back to the repo checkout.
# _resolve_canonical_template <template_filename>
# e.g. _resolve_canonical_template "issue-sync-caller.yml"
_resolve_canonical_template() {
	local _template_filename="$1"
	local _deployed="${HOME:-}/.aidevops/agents/templates/workflows/${_template_filename}"
	local _repo_local="$SELF_DIR/../templates/workflows/${_template_filename}"

	if [[ -f "$_deployed" ]]; then
		printf '%s\n' "$_deployed"
		return 0
	fi
	if [[ -n "$SELF_DIR" && -f "$_repo_local" ]]; then
		printf '%s\n' "$_repo_local"
		return 0
	fi
	return 1
}

# _resolve_canonical_reusable <reusable_filename>
# Emits the aidevops source reusable workflow path for content-update checks.
_resolve_canonical_reusable() {
	local _reusable_filename="$1"
	local _repo_local="$REPO_ROOT/.github/workflows/${_reusable_filename}"
	if [[ -n "$REPO_ROOT" && -f "$_repo_local" ]]; then
		printf '%s\n' "$_repo_local"
		return 0
	fi
	return 1
}

REPOS_JSON="${HOME:-}/.config/aidevops/repos.json"

# ─── Logging ────────────────────────────────────────────────────────────────

_log() {
	local _msg="$1"
	printf '[%s] %s\n' "$SCRIPT_NAME" "$_msg" >&2
	return 0
}

_die() {
	local _msg="$1"
	local _code="${2:-2}"
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$_msg" >&2
	exit "$_code"
}

_usage() {
	sed -n '4,56s/^# \{0,1\}//p' "$0"
	return 0
}

# ─── Reusable Target Resolution ─────────────────────────────────────────────

readonly _DEFAULT_WORKFLOW_REUSABLE_REPO="marcusquinn/aidevops"
readonly _DEFAULT_WORKFLOW_REUSABLE_REF="main"

_escape_ere() {
	local _text="$1"
	printf '%s' "$_text" | sed -E 's/[][(){}.^$*+?|]/\\&/g'
	return 0
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

_render_template_for_target() {
	local _template="$1"
	local _repo="$2"
	local _reusable_file="$3"
	local _ref="$4"
	local _default_repo_escaped _reusable_escaped _repo_repl _ref_repl
	_default_repo_escaped=$(_escape_ere "$_DEFAULT_WORKFLOW_REUSABLE_REPO")
	_reusable_escaped=$(_escape_ere "$_reusable_file")
	_repo_repl=$(_escape_sed_replacement "$_repo")
	_ref_repl=$(_escape_sed_replacement "$_ref")
	local _rendered
	_rendered=$(sed -E \
		-e "s|(uses:[[:space:]]*)${_default_repo_escaped}(/\.github/workflows/${_reusable_escaped})@[^[:space:]]+|\1${_repo_repl}\2@${_ref_repl}|" \
		-e "s|${_default_repo_escaped}(/\.github/workflows/${_reusable_escaped})|${_repo_repl}\1|g" \
		-e "s|^(      aidevops_ref:).*$|\1 ${_ref_repl}|" \
		"$_template")
	if [[ "$_repo" != "$_DEFAULT_WORKFLOW_REUSABLE_REPO" ]] &&
		printf '%s\n' "$_rendered" | grep -qE '^      aidevops_ref:'; then
		_rendered=$(
			printf '%s\n' "$_rendered" | sed -E \
				"s|^(      aidevops_ref:.*)$|      aidevops_repository: ${_repo_repl}\n\1|"
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

_caller_helper_provenance_matches() {
	local _wf="$1"
	local _target_repo="$2"
	local _target_escaped="$3"
	local _uses_ref _helper_ref _helper_repo
	_uses_ref=$(sed -nE "s|^[[:space:]]*uses:[[:space:]]*${_target_escaped}@([^[:space:]]+).*$|\1|p" "$_wf" | head -n 1)
	_helper_ref=$(sed -nE 's|^      aidevops_ref:[[:space:]]*([^[:space:]]+).*$|\1|p' "$_wf" | head -n 1)
	_helper_repo=$(sed -nE 's|^      aidevops_repository:[[:space:]]*([^[:space:]]+).*$|\1|p' "$_wf" | head -n 1)
	[[ -z "$_helper_repo" ]] && _helper_repo="$_DEFAULT_WORKFLOW_REUSABLE_REPO"
	if [[ -n "$_uses_ref" && "$_helper_ref" == "$_uses_ref" && "$_helper_repo" == "$_target_repo" ]]; then
		return 0
	fi
	return 1
}

# ─── Classification ─────────────────────────────────────────────────────────

# _normalize_wf_for_compare <file> <target_escaped>
# Normalise a workflow file for byte-comparison:
#   - Replaces the @<ref> suffix on reusable `uses:` lines with @REF so that
#     `@main` vs `@v3.9.0` doesn't count as drift.
#   - Replaces `branches: [<name>]` with `branches: [BRANCH]` so repos that
#     default to `develop` aren't flagged as drifted from a main-defaulting template.
#   - Strips injected `runner:` keys from `with:` blocks (GH#21877) and removes
#     any `    with:` block that becomes empty after runner removal, so repos
#     with a repos.json `runner` override aren't flagged as DRIFTED/CALLER.
# Emits normalised content on stdout.
_normalize_wf_for_compare() {
	local _file="$1"
	local _target_escaped="$2"
	# Step 1: normalise @ref and branch filter (existing logic).
	# Step 2: remove injected `      runner: <value>` lines.
	# Step 3: remove `    with:` block headers that are now empty (runner was
	#         the only key). Uses awk: buffer the `    with:` line, emit it
	#         only if the next line is also inside the block (6-space indent);
	#         otherwise discard the header silently.
	# GH#21899: a pending `    with:` at EOF is also empty (sed step 2 already
	#         deleted the only `runner:` child). The earlier `END { print pending }`
	#         resurrected it and made callers where `runner:` was the only `with:`
	#         entry AND `with:` ended up as the last content line in the file
	#         (e.g. callers missing `secrets: inherit`) classify as DRIFTED/CALLER.
	#         Dropping pending at EOF is correct — there is no legitimate scenario
	#         where a `with:` followed by no children should survive normalisation.
	sed -E "s|(${_target_escaped})@[^[:space:]]+|\1@REF|g" "$_file" |
		sed -E 's|^([[:space:]]+branches:) \[[^]]+\]$|\1 [BRANCH]|' |
		sed -E 's|^      aidevops_ref: .+$|      aidevops_ref: REF|' |
		sed -E '/^      aidevops_repository: /d' |
		sed -E '/^      runner: /d' |
		awk '
			/^    with:$/ { pending = $0; next }
			pending {
				if (/^      /) {
					print pending
					pending = ""
					print
					next
				}
				pending = ""
				print
				next
			}
			{ print }
		'
	return 0
}

_normalize_wf_text_for_compare() {
	local _content="$1"
	local _target_escaped="$2"
	printf '%s\n' "$_content" |
		sed -E "s|(${_target_escaped})@[^[:space:]]+|\1@REF|g" |
		sed -E 's|^([[:space:]]+branches:) \[[^]]+\]$|\1 [BRANCH]|' |
		sed -E 's|^      aidevops_ref: .+$|      aidevops_ref: REF|' |
		sed -E '/^      aidevops_repository: /d' |
		sed -E '/^      runner: /d' |
		awk '
			/^    with:$/ { pending = $0; next }
			pending {
				if (/^      /) {
					print pending
					pending = ""
					print
					next
				}
				pending = ""
				print
				next
			}
			{ print }
		'
	return 0
}

# _classify_workflow <workflow-file> <canonical-template> <reusable-file> <target-repo> <target-ref> [<canon-norm>]
# Prints the classification string on stdout.
# Returns 0 always; status is carried via the emitted string.
#
# Parameters:
#   _wf               — path to the workflow file to classify
#   _canon            — path to the canonical caller template
#   _reusable_file    — filename of the reusable workflow (e.g. "issue-sync-reusable.yml")
#   _target_repo      — configured trusted reusable workflow repository
#   _target_ref       — configured trusted reusable workflow ref, without leading @
#   _canon_norm_pre   — optional pre-computed normalised form of the canonical template
#                       (loop-invariant optimisation; skip the inner sed call when provided)
_classify_workflow() {
	local _wf="$1"
	local _canon="$2"
	local _reusable_file="$3"
	local _target_repo="$4"
	local _target_ref="$5"
	local _canon_norm_pre="${6:-}"
	local _reusable_escaped _target_escaped
	_reusable_escaped=$(_escape_ere "$_reusable_file")
	_target_escaped="$(_escape_ere "$_target_repo")/\.github/workflows/${_reusable_escaped}"

	if [[ ! -f "$_wf" ]]; then
		printf 'NO-WORKFLOW\n'
		return 0
	fi

	# Detect self-caller (aidevops itself) — uses: ./.github/workflows/<reusable-name>
	# This is the intended pattern for the aidevops repo and must not be flagged
	# as drift. The self-caller is functionally equivalent to the downstream
	# pattern; it just skips the cross-repo checkout.
	local _self_caller_pattern
	_self_caller_pattern="uses:[[:space:]]*\./\.github/workflows/${_reusable_escaped}"
	if grep -qE "$_self_caller_pattern" "$_wf"; then
		printf 'CURRENT/SELF-CALLER\n'
		return 0
	fi

	# Detect caller pattern: any `uses:` line pointing at the reusable workflow.
	# Accept any `@<ref>` variant (main, v3.9.0, a commit SHA, etc).
	local _downstream_pattern
	_downstream_pattern="uses:[[:space:]]*${_target_escaped}@"
	if grep -qE "$_downstream_pattern" "$_wf"; then
		# Helper-bearing callers must bind runtime helper provenance to the same
		# repository/ref tuple as the reusable YAML. Missing or mismatched values
		# are drift so sync-workflows can repair legacy callers safely.
		if grep -qE '^      aidevops_ref:' "$_canon" &&
			! _caller_helper_provenance_matches "$_wf" "$_target_repo" "$_target_escaped"; then
			printf 'DRIFTED/CALLER\n'
			return 0
		fi
		# It's a caller. Compare against canonical, normalising the @ref so that
		# `@main` vs `@v3.9.0` doesn't count as drift (intentional pinning is OK).
		# Also normalise the push-trigger branch filter so a repo with
		# `branches: [develop]` installed by sync-workflows is not flagged as
		# drift — the branch name reflects the downstream default, not the template.
		local _wf_norm _canon_norm
		_wf_norm=$(_normalize_wf_for_compare "$_wf" "$_target_escaped")
		# Use pre-computed canon_norm when available (caller hoist); fall back to
		# computing it here so the function remains usable in isolation.
		if [[ -n "$_canon_norm_pre" ]]; then
			_canon_norm="$_canon_norm_pre"
		else
			local _canon_rendered
			_canon_rendered=$(_render_template_for_target "$_canon" "$_target_repo" "$_reusable_file" "$_target_ref")
			_canon_norm=$(_normalize_wf_text_for_compare "$_canon_rendered" "$_target_escaped")
		fi

		if [[ "$_wf_norm" == "$_canon_norm" ]]; then
			printf 'CURRENT/CALLER\n'
		else
			printf 'DRIFTED/CALLER\n'
		fi
		return 0
	fi

	# Not a caller. The workflow exists but does not delegate to the reusable
	# pattern — it's a legacy full-copy that needs migration to the caller model.
	# This catches:
	#   - Modern full-copies that invoke the helper script directly
	#   - Older full-copies that inline the gate logic
	#   - SHA-pinned helper checkouts (the GH#20727 pattern)
	# All variants are equivalently "legacy patterns to be replaced by a caller".
	printf 'NEEDS-MIGRATION\n'
	return 0
}

# ─── Repo iteration ─────────────────────────────────────────────────────────

_expand_home_path() {
	local _path="$1"
	# Preserve ~/ when HOME is unavailable; stripping the tilde would turn the
	# configured repository into an unrelated root-relative path.
	if [[ "${_path#\~/}" != "$_path" && -n "${HOME:-}" ]]; then
		_path="${HOME}${_path#\~}"
	fi
	printf '%s\n' "$_path"
	return 0
}

_absolute_git_common_dir() {
	local _repo="$1"
	local _common_dir
	_common_dir=$(git -C "$_repo" rev-parse --git-common-dir 2>/dev/null) || return 1
	if [[ "$_common_dir" != /* ]]; then
		_common_dir=$(cd "$_repo/$_common_dir" 2>/dev/null && pwd -P) || return 1
	fi
	printf '%s\n' "$_common_dir"
	return 0
}

# _resolve_caller_worktree_root <slug>
# Prefer an explicitly supplied or current caller-owned linked worktree when it
# belongs to the registered repository. The common-dir comparison binds the
# candidate to repos.json without relying on remote URL string parsing.
_resolve_caller_worktree_root() {
	local _slug="$1"
	local _candidate="${AIDEVOPS_WORKFLOW_REPO_ROOT:-}"
	if [[ -z "$_candidate" ]]; then
		_candidate=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || return 1
	fi
	_candidate=$(git -C "$_candidate" rev-parse --show-toplevel 2>/dev/null) || return 1

	local _registered
	_registered=$(jq -r --arg s "$_slug" \
		'.initialized_repos[]? | select(.slug == $s) | .path // empty' \
		"$REPOS_JSON" 2>/dev/null | head -n 1)
	[[ -n "$_registered" ]] || return 1
	_registered=$(_expand_home_path "$_registered")

	local _candidate_git_dir _candidate_common_dir _registered_common_dir
	_candidate_git_dir=$(git -C "$_candidate" rev-parse --absolute-git-dir 2>/dev/null) || return 1
	_candidate_common_dir=$(_absolute_git_common_dir "$_candidate") || return 1
	_registered_common_dir=$(_absolute_git_common_dir "$_registered") || return 1
	[[ "$_candidate_git_dir" != "$_candidate_common_dir" ]] || return 1
	[[ "$_candidate_common_dir" == "$_registered_common_dir" ]] || return 1

	printf '%s\n' "$_candidate"
	return 0
}

# _iterate_repos — emit one "path|local_only|maintenance|slug" line per registered repo
_iterate_repos() {
	if [[ ! -f "$REPOS_JSON" ]]; then
		_die "repos.json not found at $REPOS_JSON — aidevops may not be initialised"
	fi
	if ! command -v jq >/dev/null 2>&1; then
		_die "jq required — install via Homebrew/apt or equivalent"
	fi

	# Order: path, local_only, maintenance, slug — path is never empty, so it occupies the
	# leading field. Slug (which CAN be empty for local_only repos) goes last
	# so bash's `read` with IFS=$'\t' doesn't collapse the empty-slug case
	# (tab is treated as whitespace IFS; leading empties collapse, trailing
	# empties are preserved).
	jq -r '
		.initialized_repos[]?
		| [
			(.path // ""),
			(.local_only // false | tostring),
			((if .maintenance == false then false else true end) | tostring),
			(.slug // "")
		]
		| @tsv
	' "$REPOS_JSON"
	return 0
}

# _repo_freshness <repo-path> [evidence-source]
# Emits: source\tbranch\tupstream\tahead\tbehind\tstate
# Uses only existing refs: check-workflows remains a read-only, no-network audit.
_repo_freshness() {
	local _path="$1"
	local _source="${2:-local}"
	if ! git -C "$_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		printf '%s\tunknown\tunknown\tunknown\tunknown\tunknown\n' "$_source"
		return 0
	fi

	local _branch
	_branch=$(git -C "$_path" symbolic-ref --short HEAD 2>/dev/null || printf 'DETACHED')
	local _upstream
	_upstream=$(git -C "$_path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
	if [[ -z "$_upstream" ]]; then
		printf '%s\t%s\tunknown\tunknown\tunknown\tuntracked\n' "$_source" "$_branch"
		return 0
	fi

	local _ahead _behind
	if ! read -r _ahead _behind < <(git -C "$_path" rev-list --left-right --count "HEAD...${_upstream}" 2>/dev/null); then
		printf '%s\t%s\t%s\tunknown\tunknown\tunknown\n' "$_source" "$_branch" "$_upstream"
		return 0
	fi

	local _state="current"
	if ((_ahead > 0 && _behind > 0)); then
		_state="diverged"
	elif ((_behind > 0)); then
		_state="behind"
	elif ((_ahead > 0)); then
		_state="ahead"
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$_source" "$_branch" "$_upstream" "$_ahead" "$_behind" "$_state"
	return 0
}

# _freshness_note <branch> <upstream> <ahead> <behind> <state> [evidence-source]
_freshness_note() {
	local _branch="$1"
	local _upstream="$2"
	local _ahead="$3"
	local _behind="$4"
	local _state="$5"
	local _source="${6:-local}"
	case "$_state" in
	behind)
		printf '%s evidence; %s is %s commit(s) behind %s' "$_source" "$_branch" "$_behind" "$_upstream"
		;;
	diverged)
		printf '%s evidence; %s is %s ahead and %s behind %s' \
			"$_source" "$_branch" "$_ahead" "$_behind" "$_upstream"
		;;
	esac
	return 0
}

# ─── Output formats ─────────────────────────────────────────────────────────

# _render_row_human <slug> <path> <classification> <note> [<workflow>]
_render_row_human() {
	local _slug="$1"
	local _path="$2"
	local _class="$3"
	local _note="${4:-}"
	local _workflow="${5:-}"

	# Colour-code for terminals
	local _colour_reset _colour=''
	if [[ -t 1 ]]; then
		_colour_reset=$'\e[0m'
		case "$_class" in
		CURRENT/CALLER | CURRENT/SELF-CALLER | CURRENT/REUSABLE) _colour=$'\e[32m' ;; # green
		*LEGACY_ARTIFACTS* | DRIFTED/CALLER | DRIFTED/REUSABLE) _colour=$'\e[33m' ;;  # yellow
		NEEDS-MIGRATION) _colour=$'\e[31m' ;;                                         # red
		NO-WORKFLOW | LOCAL-ONLY) _colour=$'\e[90m' ;;                                # grey
		NO-TEMPLATE) _colour=$'\e[35m' ;;                                             # magenta
		esac
	else
		_colour_reset=''
	fi

	# When multiple workflows are checked, prefix slug with [workflow] for context.
	local _label="$_slug"
	if [[ -n "$_workflow" ]]; then
		_label="[${_workflow}] ${_slug}"
	fi

	printf '  %-50s %s%-16s%s %s\n' \
		"$_label" "$_colour" "$_class" "$_colour_reset" "$_note"
	return 0
}

_render_row_json() {
	local _slug="$1"
	local _path="$2"
	local _class="$3"
	local _note="${4:-}"
	local _workflow="${5:-}"
	local _evidence_source="${6:-local}"
	local _branch="${7:-unknown}"
	local _upstream="${8:-unknown}"
	local _ahead="${9:-unknown}"
	local _behind="${10:-unknown}"
	local _freshness="${11:-unknown}"

	jq -cn \
		--arg slug "$_slug" \
		--arg path "$_path" \
		--arg class "$_class" \
		--arg note "$_note" \
		--arg workflow "$_workflow" \
		--arg evidence_source "$_evidence_source" \
		--arg branch "$_branch" \
		--arg upstream "$_upstream" \
		--arg ahead "$_ahead" \
		--arg behind "$_behind" \
		--arg freshness "$_freshness" \
		'{slug: $slug, path: $path, workflow: $workflow, classification: $class, note: $note,
		  evidence: {source: $evidence_source, branch: $branch, upstream: $upstream,
		    ahead: (($ahead | tonumber?) // null), behind: (($behind | tonumber?) // null),
		    freshness: $freshness}}'
	return 0
}

# _diff_summary <workflow-file> <canonical-template>
# Emit a compact diff summary for verbose mode.
_diff_summary() {
	local _wf="$1"
	local _canon="$2"
	if ! command -v diff >/dev/null 2>&1; then
		return 0
	fi
	# Unified diff, only show first 20 lines so a huge drift doesn't blast output.
	diff -u "$_canon" "$_wf" 2>/dev/null | head -n 20
	return 0
}

# ─── Main ───────────────────────────────────────────────────────────────────

readonly _MODE_HUMAN="human"
readonly _MODE_JSON="json"

# Parse command-line flags. Emits form-feed-delimited fields so an empty
# --repo slot is preserved when --workflow is supplied on its own.
# Exits 0 on --help. Exits 2 via _die on unknown option.
_parse_args() {
	local _filter_slug=""
	local _filter_workflow=""
	local _mode="$_MODE_HUMAN"
	local _verbose=0

	while (($# > 0)); do
		local _opt="$1"
		case "$_opt" in
		--repo)
			_filter_slug="${2:-}"
			shift 2 || _die "--repo requires an argument"
			;;
		--workflow)
			_filter_workflow="${2:-}"
			shift 2 || _die "--workflow requires an argument"
			;;
		--json)
			_mode="$_MODE_JSON"
			shift
			;;
		--verbose | -v)
			_verbose=1
			shift
			;;
		-h | --help)
			_usage
			exit 0
			;;
		*)
			_die "unknown option: $_opt"
			;;
		esac
	done

	printf '%s\034%d\034%s\034%s\n' \
		"$_mode" "$_verbose" "$_filter_slug" "$_filter_workflow"
	return 0
}

# Classify a single (repo × workflow) combination.
# Side-effects: prints a classification line; caller updates counters.
#
# Emits: class\tnote
# _classify_reusable_workflow <repo-path> <canonical-reusable> <reusable-file>
_classify_reusable_workflow() {
	local _path="$1"
	local _canonical_reusable="$2"
	local _reusable_file="$3"
	local _wf="$_path/.github/workflows/${_reusable_file}"
	if [[ ! -f "$_wf" ]]; then
		printf 'NO-WORKFLOW\treusable workflow not present for configured reusable repo\n'
		return 0
	fi
	if [[ -z "$_canonical_reusable" ]]; then
		printf 'NO-TEMPLATE\tcanonical reusable workflow missing — update check deferred\n'
		return 0
	fi
	if diff -q "$_canonical_reusable" "$_wf" >/dev/null 2>&1; then
		printf 'CURRENT/REUSABLE\treusable workflow content matches aidevops baseline\n'
	else
		printf 'DRIFTED/REUSABLE\torg-owned reusable workflow differs; review/update from aidevops baseline\n'
	fi
	return 0
}

# _classify_row <slug> <path> <local_only_flag> <canonical> <reusable_file> <workflow_file> [<canon_norm>]
_classify_row() {
	local _slug="$1"
	local _path="$2"
	local _local_only_flag="$3"
	local _canonical="$4"
	local _reusable_file="$5"
	local _workflow_file="$6"
	local _canon_norm="${7:-}"

	if [[ "$_local_only_flag" == "true" ]]; then
		printf 'LOCAL-ONLY\t\n'
		return 0
	fi

	if [[ ! -d "$_path" ]]; then
		printf 'NO-WORKFLOW\tpath not present: %s\n' "$_path"
		return 0
	fi

	local _wf="$_path/.github/workflows/${_workflow_file}"
	local _target_repo _target_ref
	_target_repo=$(_workflow_reusable_repo_for_slug "$_slug")
	_target_ref=$(_workflow_reusable_ref_for_slug "$_slug")
	if [[ "$_slug" == "$_target_repo" ]]; then
		local _canonical_reusable
		_canonical_reusable=$(_resolve_canonical_reusable "$_reusable_file") || _canonical_reusable=""
		_classify_reusable_workflow "$_path" "$_canonical_reusable" "$_reusable_file"
		return 0
	fi

	if [[ -z "$_canonical" ]]; then
		if [[ -f "$_wf" ]]; then
			printf 'NO-TEMPLATE\tcanonical template missing — classification deferred\n'
		else
			printf 'NO-WORKFLOW\t\n'
		fi
		return 0
	fi

	local _class
	_class=$(_classify_workflow "$_wf" "$_canonical" "$_reusable_file" "$_target_repo" "$_target_ref" "$_canon_norm")
	local _note=""
	case "$_class" in
	NEEDS-MIGRATION)
		_note="legacy full-copy; run: aidevops sync-workflows --apply"
		;;
	esac

	local _workflow_name="${_workflow_file%.yml}"
	local _legacy_artifacts=""
	_legacy_artifacts=$(_legacy_artifacts_for_repo "$_path" "$_workflow_name")
	if [[ -n "$_legacy_artifacts" ]]; then
		_class="${_class} + LEGACY_ARTIFACTS"
		_note="known superseded files require manual review: ${_legacy_artifacts}; no files removed"
	fi
	printf '%s\t%s\n' "$_class" "$_note"
	return 0
}

# _resolve_wf_canonical <template_file>
# Emits the canonical template path on stdout (single line).
#
# GH#21477: the previous version emitted a TSV of "canonical_path\tcanon_norm"
# so that callers could pre-compute the normalised canonical content once per
# workflow type (loop-invariant optimisation from PR #20809 / GH#20794).
# The transport was fatally broken: `IFS=$'\t' read -r` reads exactly one line,
# so _canon_norm was silently truncated to the first line of the multi-line YAML
# (~50 bytes vs ~2 KB for the full content). _classify_workflow's equality check
# at line 199 therefore always failed → every caller-pattern workflow was reported
# as DRIFTED/CALLER regardless of actual content.
#
# Fix: emit only the canonical path. _classify_workflow's built-in fallback at
# lines 195-197 recomputes _canon_norm per-repo via _normalize_wf_for_compare,
# which is the verified-correct path. Cost: ~150 extra sed pipelines per full
# run (3 workflows × <50 repos); negligible vs multi-second gh enumeration.
_resolve_wf_canonical() {
	local _template_file="$1"
	local _canonical=""
	_canonical=$(_resolve_canonical_template "$_template_file") || _canonical=""
	printf '%s\n' "$_canonical"
	return 0
}

# _classify_row_with_freshness <slug> <path> <local-only> <canonical>
#   <reusable-file> <workflow-file> <canon-norm> [evidence-source]
# Emits form-feed-delimited classification, note, and evidence fields.
_classify_row_with_freshness() {
	local _slug="$1"
	local _path="$2"
	local _local_only_flag="$3"
	local _canonical="$4"
	local _reusable_file="$5"
	local _workflow_file="$6"
	local _canon_norm="${7:-}"
	local _evidence_source="${8:-local}"
	local _class _note
	IFS=$'\t' read -r _class _note < <(_classify_row \
		"$_slug" "$_path" "$_local_only_flag" "$_canonical" \
		"$_reusable_file" "$_workflow_file" "$_canon_norm")
	local _source _branch _upstream _ahead _behind _freshness
	IFS=$'\t' read -r _source _branch _upstream _ahead _behind _freshness \
		< <(_repo_freshness "$_path" "$_evidence_source")
	local _freshness_note_text
	_freshness_note_text=$(_freshness_note \
		"$_branch" "$_upstream" "$_ahead" "$_behind" "$_freshness" "$_source")
	if [[ -n "$_freshness_note_text" ]]; then
		[[ -n "$_note" ]] && _note="${_note}; "
		_note="${_note}${_freshness_note_text}"
	fi
	printf '%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\n' \
		"$_class" "$_note" "$_source" "$_branch" "$_upstream" "$_ahead" "$_behind" "$_freshness"
	return 0
}

_render_rows_header() {
	local _mode="$1"
	if [[ "$_mode" == "$_MODE_HUMAN" ]]; then
		printf '\n  %-50s %-16s %s\n' "REPO [WORKFLOW]" "STATUS" "NOTE"
		printf '  %s\n' "$(printf '%.0s─' {1..88})"
	fi
	return 0
}

_resolve_row_checkout() {
	local _path="$1"
	local _local_only_flag="$2"
	local _slug="$3"
	local _filter_slug="$4"
	local _source="local"
	_path=$(_expand_home_path "$_path")
	if [[ -n "${_CALLER_WORKTREE_ROOT:-}" && "$_slug" == "$_filter_slug" &&
		"$_local_only_flag" != "true" ]]; then
		_path="$_CALLER_WORKTREE_ROOT"
		_source="caller-worktree"
	fi
	printf '%s\034%s\n' "$_path" "$_source"
	return 0
}

# Process all rows: for each known workflow, classify each repo, render output,
# tally. Returns exit status (1 if any drifted/needs-migration, 0 otherwise).
# _process_rows <mode> <verbose> <filter_slug> <filter_workflow>
_process_rows() {
	local _mode="$1"
	local _verbose="$2"
	local _filter_slug="$3"
	local _filter_workflow="${4:-}"

	local _any_failure=0
	local _total=0 _current=0 _drifted=0 _needs_mig=0 _legacy=0 _no_wf=0 _local_only=0 _no_template=0

	_render_rows_header "$_mode"

	local _rows
	_rows=$(_iterate_repos) || exit $?

	local _wf_tuple
	for _wf_tuple in "${_KNOWN_WORKFLOWS[@]}"; do
		local _workflow_file _reusable_file _template_file
		_workflow_file="${_wf_tuple%%:*}"
		_reusable_file="${_wf_tuple#*:}"
		_reusable_file="${_reusable_file%%:*}"
		_template_file="${_wf_tuple##*:}"

		local _workflow_name="${_workflow_file%.yml}"
		if [[ -n "$_filter_workflow" ]]; then
			local _fw_norm="${_filter_workflow%.yml}"
			[[ "$_workflow_name" != "$_fw_norm" ]] && continue
		fi

		local _canonical
		_canonical=$(_resolve_wf_canonical "$_template_file")
		# Canonical normalisation now depends on the configured reusable repo/ref for
		# each slug, so it cannot be safely hoisted per workflow type.
		local _canon_norm=""

		local _path _local_only_flag _maintenance_flag _slug
		while IFS=$'\t' read -r _path _local_only_flag _maintenance_flag _slug; do
			[[ -z "$_slug" && -z "$_path" ]] && continue
			local _label="${_slug:-$(basename "$_path")}"
			[[ (-n "$_filter_slug" && "$_slug" != "$_filter_slug") || (-z "$_filter_slug" && "$_maintenance_flag" == "false") ]] && continue

			_total=$((_total + 1))
			local _row_evidence_source
			IFS=$'\034' read -r _path _row_evidence_source < <(_resolve_row_checkout "$_path" "$_local_only_flag" "$_slug" "$_filter_slug")

			local _class _note _evidence_source _branch _upstream _ahead _behind _freshness
			IFS=$'\034' read -r _class _note _evidence_source _branch _upstream _ahead _behind _freshness \
				< <(_classify_row_with_freshness "$_slug" "$_path" "$_local_only_flag" \
					"$_canonical" "$_reusable_file" "$_workflow_file" "$_canon_norm" \
					"$_row_evidence_source")

			local _base_class="${_class% + LEGACY_ARTIFACTS}"
			if [[ "$_class" == *" + LEGACY_ARTIFACTS" ]]; then
				_legacy=$((_legacy + 1))
				_any_failure=1
			fi
			case "$_base_class" in
			LOCAL-ONLY) _local_only=$((_local_only + 1)) ;;
			NO-WORKFLOW) _no_wf=$((_no_wf + 1)) ;;
			NO-TEMPLATE) _no_template=$((_no_template + 1)) ;;
			CURRENT/CALLER | CURRENT/SELF-CALLER | CURRENT/REUSABLE) _current=$((_current + 1)) ;;
			DRIFTED/CALLER | DRIFTED/REUSABLE)
				_drifted=$((_drifted + 1))
				_any_failure=1
				((_verbose == 1)) && [[ "$_mode" == "$_MODE_HUMAN" ]] && _note="see diff below"
				;;
			NEEDS-MIGRATION)
				_needs_mig=$((_needs_mig + 1))
				_any_failure=1
				;;
			esac

			if [[ "$_mode" == "$_MODE_JSON" ]]; then
				_render_row_json "$_label" "$_path" "$_class" "$_note" "$_workflow_name" \
					"$_evidence_source" "$_branch" "$_upstream" "$_ahead" "$_behind" "$_freshness"
			else
				_render_row_human "$_label" "$_path" "$_class" "$_note" "$_workflow_name"
				if ((_verbose == 1)) && [[ "$_base_class" == "DRIFTED/CALLER" ]] && [[ -n "$_canonical" ]]; then
					echo ""
					_diff_summary "$_path/.github/workflows/${_workflow_file}" "$_canonical"
					echo ""
				elif ((_verbose == 1)) && [[ "$_base_class" == "DRIFTED/REUSABLE" ]]; then
					local _canonical_reusable
					_canonical_reusable=$(_resolve_canonical_reusable "$_reusable_file") || _canonical_reusable=""
					[[ -n "$_canonical_reusable" ]] && {
						echo ""
						_diff_summary "$_path/.github/workflows/${_reusable_file}" "$_canonical_reusable"
						echo ""
					}
				fi
			fi
		done <<<"$_rows"
	done

	if [[ "$_mode" == "$_MODE_HUMAN" ]]; then
		printf '\n  Summary: %d entries — %d current, %d drifted, %d needs-migration, %d legacy-artifacts, %d no-workflow, %d local-only, %d no-template\n\n' \
			"$_total" "$_current" "$_drifted" "$_needs_mig" "$_legacy" "$_no_wf" "$_local_only" "$_no_template"
		((_any_failure == 1)) && printf '  Exit code 1 — review drift, migrations, or legacy artifacts above.\n\n'
	fi

	return "$_any_failure"
}

main() {
	# Handle help before validating dependencies or touching repos.json. Argument
	# parsing normally runs in a process substitution below, where `exit 0` only
	# exits the subshell and would otherwise allow inventory processing to begin.
	local _arg
	for _arg in "$@"; do
		case "$_arg" in
		-h | --help)
			_usage
			return 0
			;;
		esac
	done

	# Fail fast on missing repos.json — _die inside command substitution only
	# exits the subshell, not the parent.
	if [[ ! -f "$REPOS_JSON" ]]; then
		_die "repos.json not found at $REPOS_JSON — aidevops may not be initialised"
	fi
	if ! command -v jq >/dev/null 2>&1; then
		_die "jq required — install via Homebrew/apt or equivalent"
	fi

	local _mode _verbose _filter_slug _filter_workflow
	IFS=$'\034' read -r _mode _verbose _filter_slug _filter_workflow < <(_parse_args "$@")
	_CALLER_WORKTREE_ROOT=""
	if [[ -n "$_filter_slug" ]]; then
		_CALLER_WORKTREE_ROOT=$(_resolve_caller_worktree_root "$_filter_slug") || _CALLER_WORKTREE_ROOT=""
	fi

	if _process_rows "$_mode" "$_verbose" "$_filter_slug" "$_filter_workflow"; then
		exit 0
	else
		exit 1
	fi
}

main "$@"
