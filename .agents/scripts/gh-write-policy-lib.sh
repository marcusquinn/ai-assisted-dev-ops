#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh shim write policy library
# =============================================================================
# Headless write authorization, issue/PR metadata policy, and ephemeral bodies.
# Usage: source "${_SHIM_DIR}/gh-write-policy-lib.sh"

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_GH_WRITE_POLICY_LIB_LOADED:-}" ]] && return 0
_GH_WRITE_POLICY_LIB_LOADED=1
_SHIM_ORIGIN_INTERACTIVE_LABEL="origin:interactive"
_SHIM_ISSUE_FIRST_SCOPE_EXTERNAL="external"
_SHIM_MANAGED_LABEL_SET=""

if [[ -z "${_SHIM_DIR:-}" ]]; then
	_gh_write_policy_path="${BASH_SOURCE[0]%/*}"
	[[ "$_gh_write_policy_path" == "${BASH_SOURCE[0]}" ]] && _gh_write_policy_path="."
	_SHIM_DIR="$(cd "$_gh_write_policy_path" && pwd)"
	unset _gh_write_policy_path
fi
_shim_is_headless_automation() {
	case ":${HEADLESS:-}:${FULL_LOOP_HEADLESS:-}:${AIDEVOPS_HEADLESS:-}:${OPENCODE_HEADLESS:-}:${GITHUB_ACTIONS:-}:${AIDEVOPS_SESSION_ORIGIN:-}:" in
	*:1:* | *:true:* | *:worker:* | *:pulse:* | *:routine:* | *:headless:*) return 0 ;;
	esac
	return 1
}

_shim_normalize_repo_slug() {
	local target="$1"
	target="${target#*github.com/}"
	target="${target#*github.com:}"
	target="${target%.git}"
	if [[ "$target" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		printf '%s\n' "$target"
		return 0
	fi
	return 1
}

_shim_repo_from_git_remote() {
	local remote_url=""
	remote_url=$(git remote get-url origin 2>/dev/null || true)
	[[ -z "$remote_url" ]] && return 1
	_shim_normalize_repo_slug "$remote_url"
	return $?
}

_shim_repo_from_args() {
	local args=("$@")
	local idx=0
	local arg=""
	local next=""
	while [[ $idx -lt ${#args[@]} ]]; do
		arg="${args[$idx]}"
		case "$arg" in
		--repo | -R)
			next="${args[idx + 1]:-}"
			_shim_normalize_repo_slug "$next" && return 0
			idx=$((idx + 2))
			continue
			;;
		--repo=*) _shim_normalize_repo_slug "${arg#--repo=}" && return 0 ;;
		-R*) _shim_normalize_repo_slug "${arg#-R}" && return 0 ;;
		esac
		idx=$((idx + 1))
	done
	return 1
}

_shim_repo_from_api_path_args() {
	local args=("$@")
	local idx=0
	local arg=""
	local path=""
	while [[ $idx -lt ${#args[@]} ]]; do
		arg="${args[$idx]}"
		case "$arg" in
		-f | --field | -F | --raw-field | --jq | -q | -H | --header | --input | --template | -t | --cache | --hostname | --preview | -p | -X | --method)
			idx=$((idx + 2))
			continue
			;;
		api) ;;
		/repos/* | repos/*) [[ -z "$path" ]] && path="$arg" ;;
		-*) ;;
		esac
		idx=$((idx + 1))
	done
	local npath="${path#/}"
	if [[ "$npath" =~ ^repos/([^/]+/[^/]+)(/|$|\?) ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

_shim_target_repo_slug() {
	local repo_slug=""
	repo_slug=$(_shim_repo_from_args "$@" 2>/dev/null || true)
	if [[ -z "$repo_slug" && "${1:-}" == "api" ]]; then
		repo_slug=$(_shim_repo_from_api_path_args "$@" 2>/dev/null || true)
	fi
	if [[ -z "$repo_slug" ]]; then
		repo_slug=$(_shim_repo_from_git_remote 2>/dev/null || true)
	fi
	[[ -n "$repo_slug" ]] || return 1
	printf '%s\n' "$repo_slug"
	return 0
}

_shim_repo_role() {
	local repo_slug="$1"
	local repos_json="${AIDEVOPS_REPOS_JSON:-${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}}"
	local explicit_role=""
	local configured_maintainer=""
	local current_user=""
	local slug_owner=""
	local metadata=""
	if [[ -n "$repo_slug" && -f "$repos_json" ]] && command -v jq >/dev/null 2>&1; then
		metadata=$(jq -r --arg slug "$repo_slug" '[.initialized_repos[]? | select(.slug == $slug)] | first // {} | "\(.role // "")\u001f\(.maintainer // "")"' "$repos_json" 2>/dev/null || true)
		IFS=$'\037' read -r explicit_role configured_maintainer <<<"$metadata"
		case "$explicit_role" in
		maintainer | contributor)
			printf '%s\n' "$explicit_role"
			return 0
			;;
		esac
	fi
	# Match pulse/repo metadata semantics: omitted role is derived from the
	# authenticated user and either configured maintainer or slug owner, then
	# fail-closed to contributor.
	if [[ -n "$repo_slug" && "$repo_slug" == */* && -n "${REAL_GH:-}" ]]; then
		slug_owner="${repo_slug%%/*}"
		current_user=$(_shim_run_transport "$REAL_GH" rest gh_api_user 0 api user --jq '.login' 2>/dev/null || true)
		if [[ -n "$current_user" && ( "$configured_maintainer" == "$current_user" || "$slug_owner" == "$current_user" ) ]]; then
			printf 'maintainer\n'
			return 0
		fi
	fi
	printf 'contributor\n'
	return 0
}

_shim_external_write_has_explicit_instigation() {
	local repo_slug="$1"
	local allow="${AIDEVOPS_USER_INSTIGATED_EXTERNAL_GH_WRITE:-${AIDEVOPS_EXTERNAL_GH_WRITE_ALLOWLIST:-}}"
	local item=""
	local allow_items=()
	[[ -z "$allow" ]] && return 1
	IFS=',' read -r -a allow_items <<< "$allow"
	for item in "${allow_items[@]}"; do
		item="${item#"${item%%[![:space:]]*}"}"
		item="${item%"${item##*[![:space:]]}"}"
		if [[ "$item" == "$repo_slug" ]]; then
			return 0
		fi
	done
	return 1
}

_shim_is_content_write_command() {
	case "${1:-}:${2:-}" in
	issue:comment | issue:create | issue:edit | issue:close | issue:reopen | issue:lock | issue:pin | issue:delete | \
	pr:create | pr:comment | pr:edit | pr:review | pr:merge | pr:close | pr:reopen | pr:ready | pr:lock | \
	label:create | label:edit | label:delete | release:create | release:delete | release:upload)
		return 0
		;;
	esac
	return 1
}

_shim_block_headless_external_write_if_needed() {
	_shim_is_headless_automation || return 0
	local repo_slug=""
	repo_slug=$(_shim_target_repo_slug "$@" 2>/dev/null || true)
	[[ -z "$repo_slug" ]] && return 0
	local repo_role="contributor"
	repo_role=$(_shim_repo_role "$repo_slug" 2>/dev/null || printf 'contributor\n')
	[[ "$repo_role" == "maintainer" ]] && return 0
	_shim_external_write_has_explicit_instigation "$repo_slug" && return 0
	printf '[aidevops][external-write-guard][BLOCK] Headless automation attempted a GitHub write to contributor/read-only repo %s.\n' "$repo_slug" >&2
	printf '  This repo is observe-only for unattended pulse/routine workers. Re-run interactively or set AIDEVOPS_USER_INSTIGATED_EXTERNAL_GH_WRITE=%s for this exact target.\n' "$repo_slug" >&2
	return 1
}

_shim_arg_labels_contain() {
	local labels="$1"
	local needle="$2"
	local label=""
	local label_array=()
	local IFS=,
	read -ra label_array <<< "$labels"
	for label in "${label_array[@]}"; do
		label="${label#"${label%%[![:space:]]*}"}"
		label="${label%"${label##*[![:space:]]}"}"
		if [[ "$label" == "$needle" ]]; then
			return 0
		fi
	done
	return 1
}

_shim_arg_labels_have_prefix() {
	local labels="$1"
	local prefix="$2"
	local label=""
	local label_array=()
	local IFS=,
	read -ra label_array <<< "$labels"
	for label in "${label_array[@]}"; do
		label="${label#"${label%%[![:space:]]*}"}"
		label="${label%"${label##*[![:space:]]}"}"
		if [[ "$label" == "${prefix}"* ]]; then
			return 0
		fi
	done
	return 1
}

_shim_issue_create_get_title() {
	local idx=0
	local arg=""
	local title=""
	while [[ $idx -lt ${#_modified_args[@]} ]]; do
		arg="${_modified_args[$idx]}"
		case "$arg" in
		--title | -t)
			title="${_modified_args[idx + 1]:-}"
			idx=$((idx + 2))
			continue
			;;
		--title=*)
			title="${arg#--title=}"
			;;
		-t*)
			title="${arg#-t}"
			;;
		esac
		idx=$((idx + 1))
	done
	if [[ -n "$title" ]]; then
		printf '%s\n' "$title"
		return 0
	fi
	return 1
}

_shim_issue_create_has_label() {
	local wanted="$1"
	local idx=0
	local arg=""
	while [[ $idx -lt ${#_modified_args[@]} ]]; do
		arg="${_modified_args[$idx]}"
		case "$arg" in
		--label | -l)
			_shim_arg_labels_contain "${_modified_args[idx + 1]:-}" "$wanted" && return 0
			idx=$((idx + 2))
			continue
			;;
		--label=*) _shim_arg_labels_contain "${arg#--label=}" "$wanted" && return 0 ;;
		-l*) _shim_arg_labels_contain "${arg#-l}" "$wanted" && return 0 ;;
		esac
		idx=$((idx + 1))
	done
	return 1
}

_shim_issue_create_has_label_prefix() {
	local prefix="$1"
	local idx=0
	local arg=""
	while [[ $idx -lt ${#_modified_args[@]} ]]; do
		arg="${_modified_args[$idx]}"
		case "$arg" in
		--label | -l)
			_shim_arg_labels_have_prefix "${_modified_args[idx + 1]:-}" "$prefix" && return 0
			idx=$((idx + 2))
			continue
			;;
		--label=*) _shim_arg_labels_have_prefix "${arg#--label=}" "$prefix" && return 0 ;;
		-l*) _shim_arg_labels_have_prefix "${arg#-l}" "$prefix" && return 0 ;;
		esac
		idx=$((idx + 1))
	done
	return 1
}

_shim_issue_create_has_type_label() {
	local type_label=""
	for type_label in bug enhancement documentation docs test tests refactor chore feature maintenance security; do
		_shim_issue_create_has_label "$type_label" && return 0
	done
	return 1
}

_shim_title_is_internal_tracking_issue() {
	local title="$1"
	[[ "$title" =~ ^(t[0-9]+(\.[0-9]+)*|GH#[0-9]+):[[:space:]] ]]
	return $?
}

_shim_framework_bug_candidate() {
	local title="$1"
	local body="$2"
	local has_bug_label="$3"
	_shim_title_is_internal_tracking_issue "$title" && return 1
	[[ "$has_bug_label" == "1" ]] && return 0
	[[ "$title" =~ ^[[:space:]]*[Bb][Uu][Gg]([^[:alnum:]_]|$) ]] && return 0
	grep -Eqi '^## Reproducer[[:space:]]*$' <<<"$body" && return 0
	return 1
}

_shim_advise_framework_bug_body() {
	local body="$1"
	local body_file="$2"
	local validator="${_SHIM_DIR}/log-issue-helper.sh"
	local validation_target=""
	local temporary_body=""
	local validation_output=""

	# Keep the shim's infrastructure fail-open contract when the adjacent
	# validator is unavailable. Installed framework bundles ship both files.
	[[ -f "$validator" ]] || return 0

	if [[ -n "$body_file" && -f "$body_file" ]]; then
		validation_target="$body_file"
	else
		temporary_body=$(mktemp -t aidevops-gh-issue-brief.XXXXXX 2>/dev/null) || return 0
		if ! printf '%s' "$body" >"$temporary_body"; then
			rm -f "$temporary_body"
			return 0
		fi
		validation_target="$temporary_body"
	fi

	if validation_output=$(bash "$validator" validate-brief "$validation_target" 2>&1); then
		[[ -z "$temporary_body" ]] || rm -f "$temporary_body"
		return 0
	fi

	[[ -z "$temporary_body" ]] || rm -f "$temporary_body"
	printf '[aidevops][issue-brief][WARN] Canonical aidevops framework-bug report failed final-body validation; publishing it for later enrichment.\n' >&2
	[[ -z "$validation_output" ]] || printf '%s\n' "$validation_output" >&2
	printf '  Add substantive ## Reproducer evidence or explicitly frame the report as an unconfirmed investigation when practical.\n' >&2
	return 0
}

_SHIM_ISSUE_BODY=""
_SHIM_ISSUE_BODY_FILE=""

_shim_issue_create_collect_body() {
	local idx=0
	local arg=""
	_SHIM_ISSUE_BODY=""
	_SHIM_ISSUE_BODY_FILE=""
	while [[ $idx -lt ${#_modified_args[@]} ]]; do
		arg="${_modified_args[$idx]}"
		case "$arg" in
		--body)
			_SHIM_ISSUE_BODY="${_modified_args[idx + 1]:-}"
			_SHIM_ISSUE_BODY_FILE=""
			idx=$((idx + 2))
			continue
			;;
		--body=*) _SHIM_ISSUE_BODY="${arg#--body=}"; _SHIM_ISSUE_BODY_FILE="" ;;
		--body-file)
			_SHIM_ISSUE_BODY_FILE="${_modified_args[idx + 1]:-}"
			_SHIM_ISSUE_BODY=""
			idx=$((idx + 2))
			continue
			;;
		--body-file=*) _SHIM_ISSUE_BODY_FILE="${arg#--body-file=}"; _SHIM_ISSUE_BODY="" ;;
		esac
		idx=$((idx + 1))
	done
	if [[ -n "$_SHIM_ISSUE_BODY_FILE" && -f "$_SHIM_ISSUE_BODY_FILE" ]]; then
		_SHIM_ISSUE_BODY=$(<"$_SHIM_ISSUE_BODY_FILE") || _SHIM_ISSUE_BODY=""
	fi
	return 0
}

_shim_advise_cli_issue_create_if_needed() {
	[[ "${_modified_args[0]:-}:${_modified_args[1]:-}" == "issue:create" ]] || return 0
	local repo_slug=""
	local normalized_repo=""
	local title=""
	local has_bug_label=0
	repo_slug=$(_shim_target_repo_slug "${_modified_args[@]}" 2>/dev/null || true)
	normalized_repo=$(printf '%s' "$repo_slug" | tr '[:upper:]' '[:lower:]')
	[[ "$normalized_repo" == "marcusquinn/aidevops" ]] || return 0
	title=$(_shim_issue_create_get_title 2>/dev/null || true)
	_shim_title_is_internal_tracking_issue "$title" && return 0
	_shim_issue_create_collect_body
	_shim_issue_create_has_label "bug" && has_bug_label=1
	_shim_framework_bug_candidate "$title" "$_SHIM_ISSUE_BODY" "$has_bug_label" || return 0
	_shim_advise_framework_bug_body "$_SHIM_ISSUE_BODY" "$_SHIM_ISSUE_BODY_FILE"
	return $?
}

_SHIM_API_ISSUE_METHOD=""
_SHIM_API_ISSUE_PATH=""
_SHIM_API_ISSUE_TITLE=""
_SHIM_API_ISSUE_BODY=""
_SHIM_API_ISSUE_BODY_FILE=""
_SHIM_API_ISSUE_HAS_BUG_LABEL=0

_shim_api_issue_create_collect_fields() {
	local idx=0
	local arg=""
	local field=""
	_SHIM_API_ISSUE_METHOD=""
	_SHIM_API_ISSUE_PATH=""
	_SHIM_API_ISSUE_TITLE=""
	_SHIM_API_ISSUE_BODY=""
	_SHIM_API_ISSUE_BODY_FILE=""
	_SHIM_API_ISSUE_HAS_BUG_LABEL=0
	while [[ $idx -lt ${#_modified_args[@]} ]]; do
		arg="${_modified_args[$idx]}"
		field=""
		case "$arg" in
		-X | --method)
			_SHIM_API_ISSUE_METHOD="${_modified_args[idx + 1]:-}"
			idx=$((idx + 2))
			continue
			;;
		-X*) _SHIM_API_ISSUE_METHOD="${arg#-X}" ;;
		--method=*) _SHIM_API_ISSUE_METHOD="${arg#--method=}" ;;
		/repos/* | repos/*) [[ -z "$_SHIM_API_ISSUE_PATH" ]] && _SHIM_API_ISSUE_PATH="$arg" ;;
		-f | -F | --field | --raw-field)
			field="${_modified_args[idx + 1]:-}"
			idx=$((idx + 1))
			;;
		-f*) field="${arg#-f}" ;;
		-F*) field="${arg#-F}" ;;
		--field=*) field="${arg#--field=}" ;;
		--raw-field=*) field="${arg#--raw-field=}" ;;
		esac
		case "$field" in
		title=*) _SHIM_API_ISSUE_TITLE="${field#title=}" ;;
		body=@*) _SHIM_API_ISSUE_BODY_FILE="${field#body=@}"; _SHIM_API_ISSUE_BODY="" ;;
		body=*) _SHIM_API_ISSUE_BODY="${field#body=}"; _SHIM_API_ISSUE_BODY_FILE="" ;;
		labels\[\]=bug) _SHIM_API_ISSUE_HAS_BUG_LABEL=1 ;;
		esac
		idx=$((idx + 1))
	done
	if [[ -n "$_SHIM_API_ISSUE_BODY_FILE" && -f "$_SHIM_API_ISSUE_BODY_FILE" ]]; then
		_SHIM_API_ISSUE_BODY=$(<"$_SHIM_API_ISSUE_BODY_FILE") || _SHIM_API_ISSUE_BODY=""
	fi
	return 0
}

_shim_advise_api_issue_create_if_needed() {
	[[ "${_modified_args[0]:-}" == "api" ]] || return 0
	_shim_api_issue_create_collect_fields
	local normalized_path=""
	normalized_path=$(printf '%s' "${_SHIM_API_ISSUE_PATH#/}" | tr '[:upper:]' '[:lower:]')
	[[ "$_SHIM_API_ISSUE_METHOD" == "POST" ]] || return 0
	[[ "$normalized_path" == "repos/marcusquinn/aidevops/issues" ]] || return 0
	_shim_title_is_internal_tracking_issue "$_SHIM_API_ISSUE_TITLE" && return 0
	_shim_framework_bug_candidate "$_SHIM_API_ISSUE_TITLE" "$_SHIM_API_ISSUE_BODY" "$_SHIM_API_ISSUE_HAS_BUG_LABEL" || return 0
	_shim_advise_framework_bug_body "$_SHIM_API_ISSUE_BODY" "$_SHIM_API_ISSUE_BODY_FILE"
	return $?
}

_shim_advise_framework_bug_issue_create_if_needed() {
	if [[ "${_modified_args[0]:-}:${_modified_args[1]:-}" == "issue:create" ]]; then
		_shim_advise_cli_issue_create_if_needed
		return $?
	fi
	if [[ "${_modified_args[0]:-}" == "api" ]]; then
		_shim_advise_api_issue_create_if_needed
		return $?
	fi
	return 0
}

# Dispatch intent is mechanically mutually exclusive. Preserve issue
# publication and fail safe to the explicit manual hold when one write requests
# both labels. For issue edits, adding either intent also removes its opposite.
_SHIM_DISPATCH_AUTO_LABEL="auto-dispatch"
_SHIM_DISPATCH_MANUAL_LABEL="no-auto-dispatch"
_SHIM_FILTERED_LABEL_CSV=""

_shim_filter_label_csv() {
	local labels="$1"
	local unwanted="$2"
	local label=""
	local joined=""
	local label_array=()
	local IFS=,
	_SHIM_FILTERED_LABEL_CSV=""
	read -ra label_array <<< "$labels"
	for label in "${label_array[@]}"; do
		label="${label#"${label%%[![:space:]]*}"}"
		label="${label%"${label##*[![:space:]]}"}"
		[[ -n "$label" && "$label" != "$unwanted" ]] || continue
		joined="${joined}${joined:+,}${label}"
	done
	_SHIM_FILTERED_LABEL_CSV="$joined"
	return 0
}

_shim_cli_label_action_has() {
	local action_flag="$1"
	local wanted="$2"
	local idx=0
	local arg=""
	local value=""
	while [[ $idx -lt ${#_modified_args[@]} ]]; do
		arg="${_modified_args[$idx]}"
		value=""
		if [[ "$arg" == "$action_flag" ]] ||
			[[ "$action_flag" == "--label" && "$arg" == "-l" ]]; then
			value="${_modified_args[idx + 1]:-}"
			idx=$((idx + 2))
		elif [[ "$arg" == "${action_flag}="* ]]; then
			value="${arg#*=}"
			idx=$((idx + 1))
		elif [[ "$action_flag" == "--label" && "$arg" == -l?* ]]; then
			value="${arg#-l}"
			idx=$((idx + 1))
		else
			idx=$((idx + 1))
			continue
		fi
		_shim_arg_labels_contain "$value" "$wanted" && return 0
	done
	return 1
}

_shim_filter_cli_label_action() {
	local action_flag="$1"
	local unwanted="$2"
	local idx=0
	local arg=""
	local value=""
	local -a rebuilt=()
	while [[ $idx -lt ${#_modified_args[@]} ]]; do
		arg="${_modified_args[$idx]}"
		if [[ "$arg" == "$action_flag" ]] ||
			[[ "$action_flag" == "--label" && "$arg" == "-l" ]]; then
			value="${_modified_args[idx + 1]:-}"
			_shim_filter_label_csv "$value" "$unwanted"
			[[ -z "$_SHIM_FILTERED_LABEL_CSV" ]] || rebuilt+=("$arg" "$_SHIM_FILTERED_LABEL_CSV")
			idx=$((idx + 2))
			continue
		fi
		if [[ "$arg" == "${action_flag}="* ]]; then
			value="${arg#*=}"
			_shim_filter_label_csv "$value" "$unwanted"
			[[ -z "$_SHIM_FILTERED_LABEL_CSV" ]] || rebuilt+=("${action_flag}=${_SHIM_FILTERED_LABEL_CSV}")
			idx=$((idx + 1))
			continue
		fi
		if [[ "$action_flag" == "--label" && "$arg" == -l?* ]]; then
			value="${arg#-l}"
			_shim_filter_label_csv "$value" "$unwanted"
			[[ -z "$_SHIM_FILTERED_LABEL_CSV" ]] || rebuilt+=("-l${_SHIM_FILTERED_LABEL_CSV}")
			idx=$((idx + 1))
			continue
		fi
		rebuilt+=("$arg")
		idx=$((idx + 1))
	done
	_modified_args=("${rebuilt[@]}")
	return 0
}

_shim_api_has_label_field() {
	local wanted="$1"
	local idx=0
	local arg=""
	local field=""
	while [[ $idx -lt ${#_modified_args[@]} ]]; do
		arg="${_modified_args[$idx]}"
		field=""
		case "$arg" in
		-f | -F | --field | --raw-field)
			field="${_modified_args[idx + 1]:-}"
			idx=$((idx + 2))
			;;
		-f* | -F*) field="${arg:2}"; idx=$((idx + 1)) ;;
		--field=* | --raw-field=*) field="${arg#*=}"; idx=$((idx + 1)) ;;
		*) idx=$((idx + 1)); continue ;;
		esac
		if [[ "$field" == "labels[]=${wanted}" || "$field" == "labels=${wanted}" ]]; then
			return 0
		fi
	done
	return 1
}

_shim_filter_api_label_field() {
	local unwanted="$1"
	local idx=0
	local arg=""
	local field=""
	local -a rebuilt=()
	while [[ $idx -lt ${#_modified_args[@]} ]]; do
		arg="${_modified_args[$idx]}"
		field=""
		case "$arg" in
		-f | -F | --field | --raw-field)
			field="${_modified_args[idx + 1]:-}"
			if [[ "$field" != "labels[]=${unwanted}" && "$field" != "labels=${unwanted}" ]]; then
				rebuilt+=("$arg" "$field")
			fi
			idx=$((idx + 2))
			;;
		-f* | -F*)
			field="${arg:2}"
			[[ "$field" == "labels[]=${unwanted}" || "$field" == "labels=${unwanted}" ]] || rebuilt+=("$arg")
			idx=$((idx + 1))
			;;
		--field=* | --raw-field=*)
			field="${arg#*=}"
			[[ "$field" == "labels[]=${unwanted}" || "$field" == "labels=${unwanted}" ]] || rebuilt+=("$arg")
			idx=$((idx + 1))
			;;
		*) rebuilt+=("$arg"); idx=$((idx + 1)) ;;
		esac
	done
	_modified_args=("${rebuilt[@]}")
	return 0
}

_shim_warn_dispatch_label_conflict() {
	printf '[aidevops][dispatch-labels][NORMALIZE] Removed %s because %s was requested in the same issue write; publication continues.\n' \
		"$_SHIM_DISPATCH_AUTO_LABEL" "$_SHIM_DISPATCH_MANUAL_LABEL" >&2
	return 0
}

_shim_normalize_dispatch_labels() {
	local has_auto=0
	local has_manual=0
	case "${_modified_args[0]:-}:${_modified_args[1]:-}" in
	issue:create)
		_shim_cli_label_action_has "--label" "$_SHIM_DISPATCH_AUTO_LABEL" && has_auto=1
		_shim_cli_label_action_has "--label" "$_SHIM_DISPATCH_MANUAL_LABEL" && has_manual=1
		if [[ $has_auto -eq 1 && $has_manual -eq 1 ]]; then
			_shim_filter_cli_label_action "--label" "$_SHIM_DISPATCH_AUTO_LABEL"
			_shim_warn_dispatch_label_conflict
		fi
		return 0
		;;
	issue:edit)
		_shim_cli_label_action_has "--add-label" "$_SHIM_DISPATCH_AUTO_LABEL" && has_auto=1
		_shim_cli_label_action_has "--add-label" "$_SHIM_DISPATCH_MANUAL_LABEL" && has_manual=1
		if [[ $has_manual -eq 1 ]]; then
			_shim_filter_cli_label_action "--add-label" "$_SHIM_DISPATCH_AUTO_LABEL"
			_shim_filter_cli_label_action "--remove-label" "$_SHIM_DISPATCH_MANUAL_LABEL"
			_shim_cli_label_action_has "--remove-label" "$_SHIM_DISPATCH_AUTO_LABEL" ||
				_modified_args+=(--remove-label "$_SHIM_DISPATCH_AUTO_LABEL")
			[[ $has_auto -eq 0 ]] || _shim_warn_dispatch_label_conflict
		elif [[ $has_auto -eq 1 ]]; then
			_shim_filter_cli_label_action "--remove-label" "$_SHIM_DISPATCH_AUTO_LABEL"
			_shim_cli_label_action_has "--remove-label" "$_SHIM_DISPATCH_MANUAL_LABEL" ||
				_modified_args+=(--remove-label "$_SHIM_DISPATCH_MANUAL_LABEL")
		fi
		return 0
		;;
	esac

	[[ "${_modified_args[0]:-}" == "api" ]] || return 0
	_shim_api_issue_create_collect_fields
	local normalized_path=""
	local normalized_method=""
	normalized_path=$(printf '%s' "${_SHIM_API_ISSUE_PATH#/}" | tr '[:upper:]' '[:lower:]')
	normalized_method=$(printf '%s' "$_SHIM_API_ISSUE_METHOD" | tr '[:lower:]' '[:upper:]')
	# gh api infers POST when fields are supplied and no method is explicit.
	[[ -n "$normalized_method" ]] || normalized_method="POST"
	[[ "$normalized_method" == "POST" || "$normalized_method" == "PATCH" ]] || return 0
	[[ "$normalized_path" =~ ^repos/[^/]+/[^/]+/issues(/[0-9]+(/labels)?)?$ ]] || return 0
	_shim_api_has_label_field "$_SHIM_DISPATCH_AUTO_LABEL" && has_auto=1
	_shim_api_has_label_field "$_SHIM_DISPATCH_MANUAL_LABEL" && has_manual=1
	if [[ $has_auto -eq 1 && $has_manual -eq 1 ]]; then
		_shim_filter_api_label_field "$_SHIM_DISPATCH_AUTO_LABEL"
		_shim_warn_dispatch_label_conflict
	fi
	return 0
}

_shim_managed_label_inventory_runner() {
	local repo="$1"
	# The generic provisioner consumes gh's projected name stream, whereas the
	# explicit paginator owns raw JSON pages. Keep native pagination for this
	# bounded inventory while retaining the normal transport attribution.
	AIDEVOPS_GH_EXPLICIT_PAGINATION_DISABLE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="managed-label-inventory-rest" \
		_shim_run_transport "$REAL_GH" rest gh_managed_label_inventory 0 \
		api "/repos/${repo}/labels?per_page=100" --paginate --jq '.[].name'
	return $?
}

_shim_managed_label_create_runner() {
	local repo="$1"
	local label_name="$2"
	local label_description="$3"
	local label_color="$4"
	AIDEVOPS_GH_ROUTE_DECISION="managed-label-create-rest" \
		_shim_run_transport "$REAL_GH" rest gh_managed_label_create 0 \
		label create "$label_name" --repo "$repo" \
		--description "$label_description" --color "$label_color" >/dev/null 2>&1
	return $?
}

_shim_ensure_origin_labels_for_create() {
	local repo=""
	repo=$(_shim_target_repo_slug "${_modified_args[@]}" 2>/dev/null || true)
	[[ -n "$repo" ]] || return 0
	managed_labels_ensure_origin_set "$repo" \
		_shim_managed_label_inventory_runner _shim_managed_label_create_runner
	return $?
}

_shim_ensure_tracking_labels_for_create() {
	local repo=""
	repo=$(_shim_target_repo_slug "${_modified_args[@]}" 2>/dev/null || true)
	[[ -n "$repo" ]] || return 0
	managed_labels_ensure_tracking_set "$repo" \
		_shim_managed_label_inventory_runner _shim_managed_label_create_runner
	return $?
}

_shim_ensure_requested_managed_labels_for_create() {
	case "$_SHIM_MANAGED_LABEL_SET" in
	origin) _shim_ensure_origin_labels_for_create ;;
	tracking) _shim_ensure_tracking_labels_for_create ;;
	*) return 0 ;;
	esac
	return $?
}

_shim_normalize_interactive_tracking_issue_create() {
	[[ "${_modified_args[0]:-}:${_modified_args[1]:-}" == "issue:create" ]] || return 0
	[[ -z "${FULL_LOOP_HEADLESS:-}${AIDEVOPS_HEADLESS:-}${OPENCODE_HEADLESS:-}${GITHUB_ACTIONS:-}" ]] || return 0

	local title=""
	title="$(_shim_issue_create_get_title 2>/dev/null || true)"
	[[ "$title" =~ ^(t[0-9]+(\.[0-9]+)*|GH#[0-9]+):[[:space:]] ]] || return 0
	_SHIM_MANAGED_LABEL_SET="tracking"

	_shim_issue_create_has_label_prefix "origin:" || _modified_args+=(--label "$_SHIM_ORIGIN_INTERACTIVE_LABEL")
	_shim_issue_create_has_label_prefix "status:" || _modified_args+=(--label "status:in-review")
	_shim_issue_create_has_type_label || _modified_args+=(--label "bug")
	return 0
}

_shim_normalize_pr_create_origin() {
	[[ "${_modified_args[0]:-}:${_modified_args[1]:-}" == "pr:create" ]] || return 0
	# Respect an explicit immutable origin. Raw gh callers otherwise receive the
	# same session provenance as gh_create_pr so worker drafts are recoverable.
	if _shim_issue_create_has_label_prefix "origin:"; then
		if _shim_issue_create_has_label "origin:worker" ||
			_shim_issue_create_has_label "$_SHIM_ORIGIN_INTERACTIVE_LABEL" ||
			_shim_issue_create_has_label "origin:worker-takeover"; then
			_SHIM_MANAGED_LABEL_SET="origin"
		fi
		return 0
	fi
	local origin_label="$_SHIM_ORIGIN_INTERACTIVE_LABEL"
	if _shim_is_headless_automation; then
		origin_label="origin:worker"
	fi
	_SHIM_MANAGED_LABEL_SET="origin"
	_modified_args+=(--label "$origin_label")
	return 0
}

_shim_pr_create_get_title() {
	local idx=0
	local arg=""
	local title=""
	while [[ $idx -lt ${#_modified_args[@]} ]]; do
		arg="${_modified_args[$idx]}"
		case "$arg" in
		--title | -t)
			title="${_modified_args[idx + 1]:-}"
			idx=$((idx + 2))
			continue
			;;
		--title=*) title="${arg#--title=}" ;;
		-t*) title="${arg#-t}" ;;
		esac
		idx=$((idx + 1))
	done
	if [[ -n "$title" ]]; then
		printf '%s\n' "$title"
		return 0
	fi
	return 1
}

_shim_pr_create_get_body() {
	local idx=0
	local arg=""
	local body=""
	local body_file=""
	while [[ $idx -lt ${#_modified_args[@]} ]]; do
		arg="${_modified_args[$idx]}"
		case "$arg" in
		--body)
			body="${_modified_args[idx + 1]:-}"
			idx=$((idx + 2))
			continue
			;;
		--body=*) body="${arg#--body=}" ;;
		--body-file)
			body_file="${_modified_args[idx + 1]:-}"
			if [[ -n "$body_file" && -f "$body_file" ]]; then
				body="$(<"$body_file")"
			fi
			idx=$((idx + 2))
			continue
			;;
		--body-file=*)
			body_file="${arg#--body-file=}"
			if [[ -n "$body_file" && -f "$body_file" ]]; then
				body="$(<"$body_file")"
			fi
			;;
		esac
		idx=$((idx + 1))
	done
	if [[ -n "$body" ]]; then
		printf '%s\n' "$body"
		return 0
	fi
	return 1
}

_shim_text_has_linked_issue_ref() {
	local text="$1"
	local normalized=""
	normalized=$(printf '%s\n' "$text" | tr '[:upper:]' '[:lower:]')
	if [[ "$normalized" =~ (^|[[:space:][:punct:]])(closes?|fixes?|resolves?|for|ref)[[:space:]:]+#[0-9]+ ]]; then
		return 0
	fi
	if [[ "$normalized" =~ ^(t[0-9]+([.][0-9]+)*|gh#[0-9]+)(:|[[:space:]]) ]]; then
		return 0
	fi
	return 1
}

_shim_local_repo_slug() {
	local repo_slug=""
	repo_slug=$(_shim_repo_from_git_remote 2>/dev/null || true)
	if [[ -n "$repo_slug" ]]; then
		printf '%s\n' "$repo_slug"
		return 0
	fi
	return 1
}

_shim_target_matches_local_checkout() {
	local repo_slug="$1"
	local local_slug=""
	local local_name=""
	local target_name=""
	[[ -n "$repo_slug" && "$repo_slug" == */* ]] || return 1
	local_slug=$(_shim_local_repo_slug 2>/dev/null || true)
	if [[ -n "$local_slug" && "$local_slug" == */* ]]; then
		local_name="${local_slug##*/}"
	else
		local_name="${PWD##*/}"
	fi
	target_name="${repo_slug##*/}"
	[[ -n "$local_name" && "$target_name" == "$local_name" ]]
	return $?
}

_shim_file_issue_first_scope() {
	local file_path="$1"
	local content="${2:-}"
	local marker_lines=""
	local marker_count=0
	local scope=""
	if [[ -z "$content" ]]; then
		[[ -f "$file_path" ]] || return 1
		content=$(<"$file_path") || return 1
	fi
	marker_lines=$(printf '%s\n' "$content" |
		grep -E '^[[:space:]]*<!--[[:space:]]*aidevops:issue-first-pr:scope=(external|universal)[[:space:]]*-->[[:space:]]*$' || true)
	if [[ -n "$marker_lines" ]]; then
		marker_count=$(printf '%s\n' "$marker_lines" | grep -c . || true)
	fi
	if [[ "$marker_count" -eq 1 ]]; then
		scope=$(printf '%s\n' "$marker_lines" |
			sed -nE 's/.*scope=(external|universal).*/\1/p')
		case "$scope" in
		external | universal)
			printf '%s\n' "$scope"
			return 0
			;;
		esac
	fi
	# Legacy prose, malformed markers, and contradictory/multiple declarations
	# are policy-bearing but ambiguous. Preserve fail-closed behavior instead of
	# attempting to infer exemptions from human language.
	if [[ "$marker_count" -gt 1 ]] ||
		grep -Eqi 'aidevops:issue-first-pr:(start|scope=)|issue-first|linked issue|every human-authored pr' <<<"$content"; then
		printf 'universal\n'
		return 0
	fi
	return 1
}

_shim_file_declared_issue_first_scope() {
	local file_path="$1"
	local all_marker_lines=""
	local all_marker_count=0
	local marker_lines=""
	local marker_count=0
	local scope=""
	[[ -f "$file_path" ]] || return 1
	all_marker_lines=$(grep -E 'aidevops:issue-first-pr:scope=' "$file_path" 2>/dev/null || true)
	[[ -n "$all_marker_lines" ]] || return 1
	all_marker_count=$(printf '%s\n' "$all_marker_lines" | grep -c . || true)
	marker_lines=$(grep -E '^[[:space:]]*<!--[[:space:]]*aidevops:issue-first-pr:scope=(external|universal)[[:space:]]*-->[[:space:]]*$' \
		"$file_path" 2>/dev/null || true)
	if [[ -n "$marker_lines" ]]; then
		marker_count=$(printf '%s\n' "$marker_lines" | grep -c . || true)
	fi
	if [[ "$all_marker_count" -ne 1 || "$marker_count" -ne 1 ]]; then
		printf 'universal\n'
		return 0
	fi
	scope=$(printf '%s\n' "$marker_lines" |
		sed -nE 's/.*scope=(external|universal).*/\1/p')
	case "$scope" in
	external | universal)
		printf '%s\n' "$scope"
		return 0
		;;
	esac
	printf 'universal\n'
	return 0
}

_shim_local_issue_first_scope() {
	local root=""
	local tmpl=""
	local scope=""
	local selected_scope=""
	local -a policy_files=()
	root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	policy_files+=(
		"$root/CONTRIBUTING.md"
		"$root/.github/PULL_REQUEST_TEMPLATE.md"
		"$root/.github/pull_request_template.md"
	)
	for tmpl in "$root"/.github/PULL_REQUEST_TEMPLATE/*.md "$root"/.github/pull_request_template/*.md; do
		[[ -f "$tmpl" ]] && policy_files+=("$tmpl")
	done
	# Structured declarations are authoritative. Scan them first so ordinary PR
	# template fields cannot broaden an explicit external-only policy.
	for tmpl in "${policy_files[@]}"; do
		[[ -f "$tmpl" ]] || continue
		scope=$(_shim_file_declared_issue_first_scope "$tmpl" 2>/dev/null || true)
		[[ -n "$scope" ]] || continue
		if [[ "$scope" == "universal" ]]; then
			printf 'universal\n'
			return 0
		fi
		selected_scope="$_SHIM_ISSUE_FIRST_SCOPE_EXTERNAL"
	done
	if [[ -n "$selected_scope" ]]; then
		printf '%s\n' "$selected_scope"
		return 0
	fi

	# Legacy policy prose has no deterministic exemption contract and therefore
	# remains universal until a managed scope declaration is added.
	for tmpl in "${policy_files[@]}"; do
		[[ -f "$tmpl" ]] || continue
		scope=$(_shim_file_issue_first_scope "$tmpl" 2>/dev/null || true)
		[[ -n "$scope" ]] || continue
		if [[ "$scope" == "universal" ]]; then
			printf 'universal\n'
			return 0
		fi
		selected_scope="$scope"
	done
	[[ -n "$selected_scope" ]] || return 1
	printf '%s\n' "$selected_scope"
	return 0
}

_shim_repo_issue_first_scope() {
	local repo_slug="$1"
	local scope=""
	if _shim_target_matches_local_checkout "$repo_slug"; then
		scope=$(_shim_local_issue_first_scope 2>/dev/null || true)
		if [[ -n "$scope" ]]; then
			printf '%s\n' "$scope"
			return 0
		fi
	fi
	# Keep the framework repository policy enforceable when the shim is invoked
	# from another checkout. Its managed policy declaration is external-only.
	if [[ "$repo_slug" == "marcusquinn/aidevops" ]]; then
		printf 'external\n'
		return 0
	fi
	return 1
}

_shim_authenticated_actor_has_repo_write() {
	local repo_slug="$1"
	local current_user=""
	local permission=""
	[[ -n "$repo_slug" && "$repo_slug" == */* ]] || return 1
	#aidevops:trust-boundary -- exemption requires live GitHub identity and permission.
	current_user=$(_shim_run_transport "$REAL_GH" rest gh_api_user 0 \
		api user --jq '.login // empty' 2>/dev/null) || current_user=""
	[[ -n "$current_user" && "$current_user" =~ ^[A-Za-z0-9-]+$ ]] || return 1
	permission=$(_shim_run_transport "$REAL_GH" rest gh_api_collaborator_permission 0 \
		api "/repos/${repo_slug}/collaborators/${current_user}/permission" \
		--jq '.permission // .role_name // empty' 2>/dev/null) || permission=""
	case "$permission" in
	admin | maintain | write) return 0 ;;
	esac
	return 1
}

_shim_block_pr_create_without_linked_issue_if_needed() {
	[[ "${_modified_args[0]:-}:${_modified_args[1]:-}" == "pr:create" ]] || return 0

	local repo_slug=""
	local policy_scope=""
	local title=""
	local body=""
	repo_slug=$(_shim_target_repo_slug "${_modified_args[@]}" 2>/dev/null || true)
	[[ -n "$repo_slug" ]] || return 0
	policy_scope=$(_shim_repo_issue_first_scope "$repo_slug" 2>/dev/null || true)
	[[ -n "$policy_scope" ]] || return 0

	title=$(_shim_pr_create_get_title 2>/dev/null || true)
	body=$(_shim_pr_create_get_body 2>/dev/null || true)
	if _shim_text_has_linked_issue_ref "${title}"$'\n'"${body}"; then
		return 0
	fi
	if [[ "$policy_scope" == "$_SHIM_ISSUE_FIRST_SCOPE_EXTERNAL" ]] &&
		_shim_authenticated_actor_has_repo_write "$repo_slug"; then
		return 0
	fi

	printf '[aidevops][pr-linked-issue][BLOCK] PR creation for %s is missing a linked issue reference.\n' "$repo_slug" >&2
	printf '  Target policy scope is %s; create or find the issue first, then include one of: Closes #NNN, Fixes #NNN, Resolves #NNN, For #NNN, or Ref #NNN.\n' "$policy_scope" >&2
	if [[ "$policy_scope" == "$_SHIM_ISSUE_FIRST_SCOPE_EXTERNAL" ]]; then
		printf '  GitHub could not verify admin, maintain, or write permission for the authenticated actor; the exemption fails closed.\n' >&2
	fi
	printf '  Task-prefixed titles such as GH#NNN: or tNNN: are also accepted when they map to the project task system.\n' >&2
	return 1
}
# shellcheck disable=SC2154  # body indexes are initialized by the shim before use
_shim_prepare_ephemeral_body_file() {
	local requested_body_file="$_AIDEVOPS_GH_EPHEMERAL_BODY_FILE"
	[[ -n "$requested_body_file" ]] || return 0

	local current_body_file=""
	if [[ $_body_file_idx -ge 0 ]]; then
		if [[ $_body_file_eq -eq 1 ]]; then
			current_body_file="${_modified_args[_body_file_idx]#--body-file=}"
		else
			current_body_file="${_modified_args[_body_file_idx + 1]:-}"
		fi
	fi
	local body_parent="${requested_body_file%/*}"
	local body_name="${requested_body_file##*/}"
	local parent_name="${body_parent##*/}"
	local managed_root="${AIDEVOPS_TEMP_DIR:-${HOME:?}/.aidevops/.agent-workspace/tmp}"
	managed_root=$(cd "$managed_root" 2>/dev/null && pwd -L) || {
		printf '[aidevops][gh-ephemeral-body][BLOCK] Managed temporary root is unavailable.\n' >&2
		return 1
	}

	if [[ "$requested_body_file" != /* || "$current_body_file" != "$requested_body_file" || \
		"$body_name" != "comment.md" || \
		! "$parent_name" =~ ^aidevops-triage-comment\.[A-Za-z0-9]+$ || \
		"${body_parent%/*}" != "$managed_root" || \
		! -d "$body_parent" || -L "$body_parent" || \
		! -f "$requested_body_file" || -L "$requested_body_file" ]]; then
		printf '[aidevops][gh-ephemeral-body][BLOCK] Body is not a valid managed triage comment artifact.\n' >&2
		return 1
	fi
	if ! grep -Fqx '<!-- aidevops:sig -->' "$requested_body_file" 2>/dev/null; then
		printf '[aidevops][gh-ephemeral-body][BLOCK] Ephemeral body lacks the canonical signature marker.\n' >&2
		return 1
	fi
	if ! exec 9<"$requested_body_file"; then
		printf '[aidevops][gh-ephemeral-body][BLOCK] Unable to open the validated body descriptor.\n' >&2
		return 1
	fi
	if ! rm -f -- "$requested_body_file" || ! rmdir -- "$body_parent" || \
		[[ -e "$requested_body_file" || -L "$requested_body_file" || \
			-e "$body_parent" || -L "$body_parent" ]]; then
		exec 9<&-
		printf '[aidevops][gh-ephemeral-body][BLOCK] Managed body cleanup could not be verified before transport.\n' >&2
		return 1
	fi

	if [[ $_body_file_eq -eq 1 ]]; then
		_modified_args[_body_file_idx]="--body-file=/dev/fd/9"
	else
		_modified_args[_body_file_idx + 1]="/dev/fd/9"
	fi
	_body_file_val="/dev/fd/9"
	_AIDEVOPS_GH_EPHEMERAL_BODY_FILE=""
	return 0
}
