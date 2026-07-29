#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# badges-check-helper.sh — detect README badge block drift across registered repos (t2975).
#
# Iterates all registered repos and classifies each one's README badge block
# against the canonical rendered output from readme-badges-helper.sh.
#
# Classifies each repo as:
#
#   CURRENT     — badge block is present and matches what would be rendered
#   DRIFTED     — badge block is present but has drifted from the canonical render
#   METRICS-MISSING — badge block is current but local metrics artifacts are absent
#   NO-README   — no README.md found in the repo directory
#   NO-BLOCK    — README exists but no aidevops:badges:start/end markers
#   LOCAL-ONLY  — repo has `local_only: true`, skip
#   EXTERNAL    — repo is in a non-owned org or contributed: true (read-only info)
#
# Check (drift detection) enumerates maintained non-local-only repos by default.
# An explicit --repo check may inspect a dormant registration.
# The owned-org filter applies only to sync/install (write) operations.
#
# Usage:
#   badges-check-helper.sh [--repo OWNER/REPO] [--json] [--verbose]
#   badges-check-helper.sh --help
#
# Options:
#   --repo OWNER/REPO   Check only the named slug (default: all registered)
#   --json              Machine-readable output (one JSON object per repo)
#   --verbose           Show diff summary for DRIFTED entries
#   -h, --help          Show usage and exit 0
#
# Exit codes:
#   0  — all checked repos are CURRENT, NO-README, NO-BLOCK, or LOCAL-ONLY
#   1  — one or more repos are DRIFTED or METRICS-MISSING
#   2  — configuration or IO error (repos.json missing, jq unavailable)
#
# Owned-orgs allowlist (used for informational EXTERNAL classification):
#   marcusquinn, essentials-com, wpallstars
#   Override by creating ~/.config/aidevops/badge-orgs.conf with one org per line.

set -uo pipefail

SCRIPT_NAME=$(basename "$0")

# ─── Path resolution ────────────────────────────────────────────────────────

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_JSON="$HOME/.config/aidevops/repos.json"

# Locate readme-badges-helper.sh: prefer deployed copy, then repo checkout.
_resolve_badges_helper() {
	local _deployed="$HOME/.aidevops/agents/scripts/readme-badges-helper.sh"
	local _repo_local="$SELF_DIR/readme-badges-helper.sh"
	if [[ -x "$_deployed" ]]; then
		printf '%s\n' "$_deployed"
		return 0
	fi
	if [[ -x "$_repo_local" ]]; then
		printf '%s\n' "$_repo_local"
		return 0
	fi
	return 1
}

# ─── Owned-orgs allowlist ───────────────────────────────────────────────────

# Default owned orgs — expanded via ~/.config/aidevops/badge-orgs.conf if present.
readonly _DEFAULT_OWNED_ORGS=("marcusquinn" "essentials-com" "wpallstars")

_load_owned_orgs() {
	local _conf="$HOME/.config/aidevops/badge-orgs.conf"
	if [[ -f "$_conf" ]]; then
		# Read non-blank, non-comment lines
		while IFS= read -r _org; do
			[[ -z "$_org" || "${_org:0:1}" == "#" ]] && continue
			printf '%s\n' "$_org"
		done <"$_conf"
		return 0
	fi
	# Fall back to defaults
	local _o
	for _o in "${_DEFAULT_OWNED_ORGS[@]}"; do
		printf '%s\n' "$_o"
	done
	return 0
}

# _is_owned_org <org>
# Returns 0 if org is in the owned-orgs list, 1 otherwise.
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

_repo_metrics_missing_note() {
	local _path="$1"
	local _missing=()
	local _rel
	for _rel in \
		"docs/metrics/repo-metrics.json" \
		"docs/metrics/repo-metrics.md" \
		"docs/metrics/badges/loc.svg" \
		"docs/metrics/badges/languages.svg" \
		"docs/metrics/badges/dependencies.svg"; do
		if [[ ! -f "$_path/$_rel" ]]; then
			_missing+=("$_rel")
		fi
	done
	if [[ ${#_missing[@]} -eq 0 ]]; then
		return 1
	fi
	printf 'missing metrics artifacts: %s' "${_missing[*]}"
	return 0
}

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
	sed -n '4,39s/^# \{0,1\}//p' "$0"
	return 0
}

# ─── Repo iteration ─────────────────────────────────────────────────────────

# Emit one "path|local_only|contributed|role|maintenance|slug" TSV line per registered repo.
_iterate_repos() {
	if [[ ! -f "$REPOS_JSON" ]]; then
		_die "repos.json not found at $REPOS_JSON — aidevops may not be initialised"
	fi
	if ! command -v jq >/dev/null 2>&1; then
		_die "jq required — install via Homebrew/apt or equivalent"
	fi

	jq -r '
		.initialized_repos[]?
		| [
			(.path // ""),
			(.local_only // false | tostring),
			(.contributed // false | tostring),
			(.role // "maintainer"),
			((if .maintenance == false then false else true end) | tostring),
			(.slug // "")
		]
		| @tsv
	' "$REPOS_JSON"
	return 0
}

# ─── Classification ─────────────────────────────────────────────────────────

# _classify_badges_repo <path> <local_only> <contributed> <role> <slug> <badges_helper>
# Emits: class\tnote
_classify_badges_repo() {
	local _path="$1"
	local _local_only="$2"
	local _contributed="$3"
	local _role="$4"
	local _slug="$5"
	local _badges_helper="$6"

	if [[ "$_local_only" == "true" ]]; then
		printf 'LOCAL-ONLY\t\n'
		return 0
	fi

	# Classify scope: EXTERNAL if contributed or org not in owned list
	local _org="${_slug%%/*}"
	local _is_external=0
	if [[ "$_contributed" == "true" || "$_role" == "contributor" ]]; then
		_is_external=1
	elif [[ -n "$_org" ]] && ! _is_owned_org "$_org"; then
		_is_external=1
	fi

	if [[ ! -d "$_path" ]]; then
		if [[ "$_is_external" -eq 1 ]]; then
			printf 'EXTERNAL\tpath not present\n'
		else
			printf 'NO-README\tpath not present: %s\n' "$_path"
		fi
		return 0
	fi

	# Look for README.md (case-insensitive fallback to README.md only for now)
	local _readme="$_path/README.md"
	if [[ ! -f "$_readme" ]]; then
		if [[ "$_is_external" -eq 1 ]]; then
			printf 'EXTERNAL\tno README.md\n'
		else
			printf 'NO-README\t\n'
		fi
		return 0
	fi

	# Check for badge block markers
	if ! grep -qF '<!-- aidevops:badges:start -->' "$_readme" 2>/dev/null; then
		if [[ "$_is_external" -eq 1 ]]; then
			printf 'EXTERNAL\tno badge block\n'
		else
			printf 'NO-BLOCK\trun: aidevops badges sync --repo %s --apply\n' "$_slug"
		fi
		return 0
	fi

	if [[ "$_is_external" -eq 1 ]]; then
		# EXTERNAL repos can have a block but we still only classify as EXTERNAL
		printf 'EXTERNAL\tbadge block present\n'
		return 0
	fi

	# Run check against rendered canonical block
	local _check_rc=0
	bash "$_badges_helper" check "$_readme" "$_slug" 2>/dev/null
	_check_rc=$?

	if [[ "$_check_rc" -eq 0 ]]; then
		local _metrics_note
		if _metrics_note=$(_repo_metrics_missing_note "$_path"); then
			printf 'METRICS-MISSING\trun: aidevops badges sync --repo %s --apply (%s)\n' "$_slug" "$_metrics_note"
		else
			printf 'CURRENT\t\n'
		fi
	elif [[ "$_check_rc" -eq 3 ]]; then
		printf 'DRIFTED\trun: aidevops badges sync --repo %s --apply\n' "$_slug"
	else
		printf 'DRIFTED\tbadges helper returned %d\n' "$_check_rc"
	fi
	return 0
}

# ─── Output formats ─────────────────────────────────────────────────────────

readonly _MODE_HUMAN="human"
readonly _MODE_JSON="json"

_render_row_human() {
	local _slug="$1"
	local _class="$2"
	local _note="${3:-}"

	local _colour_reset _colour=''
	if [[ -t 1 ]]; then
		_colour_reset=$'\e[0m'
		case "$_class" in
		CURRENT) _colour=$'\e[32m' ;;          # green
		DRIFTED | METRICS-MISSING) _colour=$'\e[33m' ;; # yellow
		NO-README | NO-BLOCK) _colour=$'\e[31m' ;; # red
		LOCAL-ONLY | EXTERNAL) _colour=$'\e[90m' ;; # grey
		esac
	else
		_colour_reset=''
	fi

	printf '  %-50s %s%-12s%s %s\n' \
		"$_slug" "$_colour" "$_class" "$_colour_reset" "$_note"
	return 0
}

_render_row_json() {
	local _slug="$1"
	local _path="$2"
	local _class="$3"
	local _note="${4:-}"

	jq -cn \
		--arg slug "$_slug" \
		--arg path "$_path" \
		--arg class "$_class" \
		--arg note "$_note" \
		'{slug: $slug, path: $path, classification: $class, note: $note}'
	return 0
}

# ─── Arg parsing ────────────────────────────────────────────────────────────

_parse_args() {
	local _filter_slug=""
	local _mode="$_MODE_HUMAN"
	local _verbose=0

	while (($# > 0)); do
		local _opt="$1"
		case "$_opt" in
		--repo)
			_filter_slug="${2:-}"
			shift 2 || _die "--repo requires an argument"
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

	printf '%s\t%d\t%s\n' "$_mode" "$_verbose" "$_filter_slug"
	return 0
}

# ─── Main ───────────────────────────────────────────────────────────────────

# _process_repos <mode> <verbose> <filter_slug>
_process_repos() {
	local _mode="$1"
	local _verbose="$2"
	local _filter_slug="$3"

	local _badges_helper
	if ! _badges_helper=$(_resolve_badges_helper); then
		_die "readme-badges-helper.sh not found — run: aidevops update"
	fi

	local _any_failure=0
	local _total=0 _current=0 _drifted=0 _metrics_missing=0 _no_readme=0 _no_block=0 _local_only=0 _external=0

	if [[ "$_mode" == "$_MODE_HUMAN" ]]; then
		printf '\n  %-50s %-12s %s\n' "REPO" "STATUS" "NOTE"
		printf '  %s\n' "$(printf '%.0s─' {1..88})"
	fi

	local _rows
	_rows=$(_iterate_repos) || exit $?

	local _path _local_only_flag _contributed_flag _role _maintenance_flag _slug
	while IFS=$'\t' read -r _path _local_only_flag _contributed_flag _role _maintenance_flag _slug; do
		[[ -z "$_slug" && -z "$_path" ]] && continue
		local _label="${_slug:-$(basename "$_path")}"
		[[ -n "$_filter_slug" && "$_slug" != "$_filter_slug" ]] && continue
		[[ -z "$_filter_slug" && "$_maintenance_flag" == "false" ]] && continue

		_total=$((_total + 1))
		_path="${_path/#\~/$HOME}"

		local _class _note
		IFS=$'\t' read -r _class _note < <(_classify_badges_repo \
			"$_path" "$_local_only_flag" "$_contributed_flag" "$_role" "$_slug" "$_badges_helper")

		case "$_class" in
		LOCAL-ONLY) _local_only=$((_local_only + 1)) ;;
		EXTERNAL) _external=$((_external + 1)) ;;
		NO-README) _no_readme=$((_no_readme + 1)) ;;
		NO-BLOCK) _no_block=$((_no_block + 1)) ;;
		CURRENT) _current=$((_current + 1)) ;;
		DRIFTED)
			_drifted=$((_drifted + 1))
			_any_failure=1
			;;
		METRICS-MISSING)
			_metrics_missing=$((_metrics_missing + 1))
			_any_failure=1
			;;
		esac

		if [[ "$_mode" == "$_MODE_JSON" ]]; then
			_render_row_json "$_label" "$_path" "$_class" "$_note"
		else
			_render_row_human "$_label" "$_class" "$_note"
			if ((_verbose == 1)) && [[ "$_class" == "DRIFTED" ]]; then
				echo ""
				# Show diff for verbose DRIFTED entries
				local _readme_path="$_path/README.md"
				if [[ -f "$_readme_path" ]] && command -v diff >/dev/null 2>&1; then
					local _rendered
					_rendered=$(bash "$_badges_helper" render "$_slug" 2>/dev/null || true)
					if [[ -n "$_rendered" ]]; then
						diff -u \
							<(bash "$_badges_helper" check "$_readme_path" "$_slug" 2>&1 | head -40 || true) \
							<(printf '%s\n' "$_rendered" | head -40) \
							2>/dev/null | head -20 || true
					fi
				fi
				echo ""
			fi
		fi
	done <<<"$_rows"

	if [[ "$_mode" == "$_MODE_HUMAN" ]]; then
		printf '\n  Summary: %d entries — %d current, %d drifted, %d metrics-missing, %d no-block, %d no-readme, %d external, %d local-only\n\n' \
			"$_total" "$_current" "$_drifted" "$_metrics_missing" "$_no_block" "$_no_readme" "$_external" "$_local_only"
		((_any_failure == 1)) && printf '  Exit code 1 — see DRIFTED or METRICS-MISSING entries above.\n\n'
	fi

	return "$_any_failure"
}

main() {
	# Handle --help / -h early so exit 0 fires in the main process,
	# not inside a process substitution subshell where it would be swallowed.
	local _a
	for _a in "$@"; do
		case "$_a" in
		-h | --help) _usage; exit 0 ;;
		esac
	done

	if [[ ! -f "$REPOS_JSON" ]]; then
		_die "repos.json not found at $REPOS_JSON — aidevops may not be initialised"
	fi
	if ! command -v jq >/dev/null 2>&1; then
		_die "jq required — install via Homebrew/apt or equivalent"
	fi

	local _mode _verbose _filter_slug
	IFS=$'\t' read -r _mode _verbose _filter_slug < <(_parse_args "$@")

	if _process_repos "$_mode" "$_verbose" "$_filter_slug"; then
		exit 0
	else
		exit 1
	fi
}

main "$@"
