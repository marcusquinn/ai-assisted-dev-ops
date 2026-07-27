#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Read-only inventory and verification for GitHub release publication controls.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

readonly RELEASE_ENVIRONMENT="release"
readonly RELEASE_RULESET_NAME="Protect aidevops release tags"
readonly RELEASE_REF_PATTERN="refs/tags/v*"
readonly RELEASE_DEPLOYMENT_PATTERN="v*"
readonly RELEASE_RECOVERY_BRANCH="main"
readonly SNAPSHOT_SCHEMA="aidevops.release-publication-settings/v1"
readonly REQUIRED_REVIEWERS_RULE="required_reviewers"
readonly USER_ACTOR_TYPE="User"

_release_settings_error() {
	local message="$1"
	printf 'release-settings: %s\n' "$message" >&2
	return 1
}

_release_settings_usage() {
	cat <<'USAGE'
Usage:
  release-publication-settings-helper.sh snapshot --repo OWNER/REPO [--output FILE]
  release-publication-settings-helper.sh verify-github --repo OWNER/REPO \
    --release-author LOGIN (--unattended | --reviewer LOGIN [--reviewer LOGIN ...])

Commands are read-only. snapshot records rollback inputs before a live settings
change. verify-github checks API-visible GitHub controls after an approved change.
npm Trusted Publisher identity and the environment admin-bypass toggle require
separate npmjs.com/GitHub UI verification because their supported management APIs
do not expose those settings.
USAGE
	return 0
}

_release_settings_require_dependencies() {
	local dependency=""
	for dependency in gh jq; do
		if ! command -v "$dependency" >/dev/null 2>&1; then
			_release_settings_error "missing dependency: ${dependency}"
			return 1
		fi
	done
	return 0
}

_release_settings_validate_repo() {
	local repo_slug="$1"
	if [[ ! "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		_release_settings_error "repository must be OWNER/REPO"
		return 1
	fi
	return 0
}

_release_settings_validate_login() {
	local login="$1"
	if [[ ! "$login" =~ ^[A-Za-z0-9-]+$ ]]; then
		_release_settings_error "invalid GitHub login: ${login}"
		return 1
	fi
	return 0
}

_release_settings_api_read() {
	local endpoint="$1"
	gh api --method GET "$endpoint"
	return $?
}

_release_settings_api_array_list() {
	local endpoint="$1"
	gh api --method GET --paginate "$endpoint" | jq -cs 'add'
	return $?
}

_release_settings_api_environment_list() {
	local endpoint="$1"
	gh api --method GET --paginate "$endpoint" | jq -cs '
		{total_count: ([.[].environments[]?] | length),
		 environments: [.[].environments[]?]}'
	return $?
}

_release_settings_ruleset_details() {
	local repo_slug="$1"
	local ruleset_list="$2"
	local details='[]'
	local ruleset_id=""
	local detail=""

	while IFS= read -r ruleset_id; do
		[[ -n "$ruleset_id" ]] || continue
		detail=$(_release_settings_api_read "repos/${repo_slug}/rulesets/${ruleset_id}") || return 1
		details=$(jq -cn --argjson current "$details" --argjson item "$detail" \
			'$current + [$item]') || return 1
	done < <(jq -r '.[].id // empty' <<<"$ruleset_list")

	printf '%s\n' "$details"
	return 0
}

_release_settings_environment_snapshot() {
	local repo_slug="$1"
	local environment_list="$2"
	local environment_detail='null'
	local deployment_policies='{"total_count":0,"branch_policies":[]}'

	if jq -e --arg name "$RELEASE_ENVIRONMENT" \
		'.environments | any(.name == $name)' <<<"$environment_list" >/dev/null; then
		environment_detail=$(_release_settings_api_read \
			"repos/${repo_slug}/environments/${RELEASE_ENVIRONMENT}") || return 1
		deployment_policies=$(_release_settings_api_read \
			"repos/${repo_slug}/environments/${RELEASE_ENVIRONMENT}/deployment-branch-policies") || return 1
	fi

	jq -cn --argjson detail "$environment_detail" --argjson policies "$deployment_policies" \
		'{detail:$detail, deployment_policies:$policies}'
	return $?
}

_release_settings_capture_snapshot() {
	local repo_slug="$1"
	local repository_state=""
	local workflow_permissions=""
	local actions_policy=""
	local ruleset_list=""
	local ruleset_details=""
	local environment_list=""
	local environment_state=""

	repository_state=$(_release_settings_api_read "repos/${repo_slug}") || return 1
	workflow_permissions=$(_release_settings_api_read \
		"repos/${repo_slug}/actions/permissions/workflow") || return 1
	actions_policy=$(_release_settings_api_read "repos/${repo_slug}/actions/permissions") || return 1
	ruleset_list=$(_release_settings_api_array_list "repos/${repo_slug}/rulesets") || return 1
	ruleset_details=$(_release_settings_ruleset_details "$repo_slug" "$ruleset_list") || return 1
	environment_list=$(_release_settings_api_environment_list \
		"repos/${repo_slug}/environments") || return 1
	environment_state=$(_release_settings_environment_snapshot \
		"$repo_slug" "$environment_list") || return 1

	jq -n \
		--arg schema "$SNAPSHOT_SCHEMA" \
		--arg captured_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
		--arg repo "$repo_slug" \
		--argjson repository "$repository_state" \
		--argjson workflow_permissions "$workflow_permissions" \
		--argjson actions_policy "$actions_policy" \
		--argjson ruleset_list "$ruleset_list" \
		--argjson ruleset_details "$ruleset_details" \
		--argjson environment_list "$environment_list" \
		--argjson release_environment "$environment_state" \
		'{schema:$schema, captured_at:$captured_at, repository:$repo,
		  repository_state:{default_branch:$repository.default_branch,
		    visibility:$repository.visibility, permissions:$repository.permissions},
		  actions:{workflow_permissions:$workflow_permissions, policy:$actions_policy},
		  rulesets:{list:$ruleset_list, details:$ruleset_details},
		  environments:{list:$environment_list, release:$release_environment}}'
	return $?
}

_release_settings_write_snapshot() {
	local snapshot="$1"
	local output_file="$2"
	local parent_dir="."

	if [[ "$output_file" == */* ]]; then
		parent_dir="${output_file%/*}"
	fi
	[[ -d "$parent_dir" ]] || {
		_release_settings_error "snapshot parent directory does not exist: ${parent_dir}"
		return 1
	}
	[[ ! -e "$output_file" ]] || {
		_release_settings_error "refusing to overwrite snapshot: ${output_file}"
		return 1
	}
	if ! (
		umask 077
		set -o noclobber
		printf '%s\n' "$snapshot" >"$output_file"
	); then
		_release_settings_error "refusing to overwrite snapshot: ${output_file}"
		return 1
	fi
	printf 'SNAPSHOT_FILE=%s\n' "$output_file"
	return 0
}

_release_settings_snapshot_command() {
	local repo_slug=""
	local output_file=""

	while [[ $# -gt 0 ]]; do
		local option="$1"
		shift
		case "$option" in
		--repo)
			local repo_arg="${1:-}"
			repo_slug="$repo_arg"
			shift || true
			;;
		--output)
			local output_arg="${1:-}"
			output_file="$output_arg"
			shift || true
			;;
		*)
			_release_settings_error "unknown snapshot option: ${option}"
			return 1
			;;
		esac
	done

	_release_settings_validate_repo "$repo_slug" || return 1
	local snapshot=""
	snapshot=$(_release_settings_capture_snapshot "$repo_slug") || return 1
	if [[ -n "$output_file" ]]; then
		_release_settings_write_snapshot "$snapshot" "$output_file"
		return $?
	fi
	jq '.' <<<"$snapshot"
	return $?
}

_release_settings_resolve_user_id() {
	local login="$1"
	_release_settings_validate_login "$login" || return 1
	_release_settings_api_read "users/${login}" | jq -er '.id'
	return $?
}

_release_settings_verify_release_author() {
	local repo_slug="$1"
	local release_author="$2"
	local permission_state=""

	permission_state=$(_release_settings_api_read \
		"repos/${repo_slug}/collaborators/${release_author}/permission") || return 1
	if ! jq -e --arg login "$release_author" '
		.user.login == $login and (.permission == "admin" or .role_name == "admin")
	' <<<"$permission_state" >/dev/null; then
		_release_settings_error "release author must retain repository admin authority"
		return 1
	fi
	return 0
}

_release_settings_verify_actions() {
	local repo_slug="$1"
	local workflow_permissions=""

	workflow_permissions=$(_release_settings_api_read \
		"repos/${repo_slug}/actions/permissions/workflow") || return 1
	if ! jq -e '.default_workflow_permissions == "read"
		and .can_approve_pull_request_reviews == false' \
		<<<"$workflow_permissions" >/dev/null; then
		_release_settings_error "Actions defaults are not read-only with PR approval disabled"
		return 1
	fi
	return 0
}

_release_settings_release_ruleset() {
	local repo_slug="$1"
	local ruleset_list=""
	local ruleset_id=""

	ruleset_list=$(_release_settings_api_array_list "repos/${repo_slug}/rulesets") || return 1
	ruleset_id=$(jq -er --arg name "$RELEASE_RULESET_NAME" '
		map(select(.name == $name and .target == "tag" and .enforcement == "active"))
		| if length == 1 then .[0].id else error("expected exactly one release ruleset") end
	' <<<"$ruleset_list") || {
		_release_settings_error "active release tag ruleset is missing or ambiguous"
		return 1
	}
	_release_settings_api_read "repos/${repo_slug}/rulesets/${ruleset_id}"
	return $?
}

_release_settings_verify_ruleset() {
	local repo_slug="$1"
	local release_author="$2"
	local author_id=""
	local ruleset_detail=""

	author_id=$(_release_settings_resolve_user_id "$release_author") || return 1
	ruleset_detail=$(_release_settings_release_ruleset "$repo_slug") || return 1
	if ! jq -e \
		--arg pattern "$RELEASE_REF_PATTERN" \
		--arg user_type "$USER_ACTOR_TYPE" \
		--argjson author_id "$author_id" '
		.target == "tag"
		and .enforcement == "active"
		and ((.conditions.ref_name.include // []) == [$pattern])
		and ((.conditions.ref_name.exclude // []) == [])
		and (([.rules[]?.type] | sort) == (["creation", "update", "deletion"] | sort))
		and ([.bypass_actors[]?] | length == 1)
		and any(.bypass_actors[]?;
		  .actor_type == $user_type and .actor_id == $author_id and .bypass_mode == "always")
	' <<<"$ruleset_detail" >/dev/null; then
		_release_settings_error "release tag ruleset does not match the fail-closed policy"
		return 1
	fi
	return 0
}

_release_settings_verify_reviewers() {
	local environment_detail="$1"
	shift
	local expected_count="$#"
	local reviewer=""
	local seen_reviewers=" "

	if ! jq -e --arg rule "$REQUIRED_REVIEWERS_RULE" \
		--arg user_type "$USER_ACTOR_TYPE" --argjson count "$expected_count" '
		[.protection_rules[]? | select(.type == $rule)] as $rules
		| ($rules | length) == 1
		and $rules[0].prevent_self_review == false
		and (($rules[0].reviewers // []) | length) == $count
		and all($rules[0].reviewers[]?;
		  .type == $user_type and (.reviewer.login | type == "string"))
	' <<<"$environment_detail" >/dev/null; then
		_release_settings_error "release environment reviewer set is not exact"
		return 1
	fi
	for reviewer in "$@"; do
		_release_settings_validate_login "$reviewer" || return 1
		if [[ "$seen_reviewers" == *" ${reviewer} "* ]]; then
			_release_settings_error "duplicate required reviewer: ${reviewer}"
			return 1
		fi
		seen_reviewers+="${reviewer} "
		if ! jq -e --arg login "$reviewer" --arg rule "$REQUIRED_REVIEWERS_RULE" \
			--arg user_type "$USER_ACTOR_TYPE" \
			'any(.protection_rules[]?; .type == $rule
			and any(.reviewers[]?; .type == $user_type and .reviewer.login == $login))' \
			<<<"$environment_detail" >/dev/null; then
			_release_settings_error "missing required reviewer: ${reviewer}"
			return 1
		fi
	done
	return 0
}

_release_settings_verify_unattended() {
	local environment_detail="$1"
	if ! jq -e --arg reviewers_rule "$REQUIRED_REVIEWERS_RULE" '
		([.protection_rules[]? | select(.type == $reviewers_rule)] | length) == 0
		and ([.protection_rules[]? | select(.type == "wait_timer")] | length) == 0
	' <<<"$environment_detail" >/dev/null; then
		_release_settings_error "release environment still has a manual reviewer or wait-timer gate"
		return 1
	fi
	return 0
}

_release_settings_verify_environment() {
	local repo_slug="$1"
	local approval_mode="$2"
	shift
	shift
	local environment_detail=""
	local deployment_policies=""

	environment_detail=$(_release_settings_api_read \
		"repos/${repo_slug}/environments/${RELEASE_ENVIRONMENT}") || return 1
	if ! jq -e '.deployment_branch_policy.protected_branches == false
		and .deployment_branch_policy.custom_branch_policies == true' \
		<<<"$environment_detail" >/dev/null; then
		_release_settings_error "release environment does not use custom ref policies"
		return 1
	fi
	if [[ "$approval_mode" == "unattended" ]]; then
		_release_settings_verify_unattended "$environment_detail" || return 1
	else
		_release_settings_verify_reviewers "$environment_detail" "$@" || return 1
	fi

	deployment_policies=$(_release_settings_api_read \
		"repos/${repo_slug}/environments/${RELEASE_ENVIRONMENT}/deployment-branch-policies") || return 1
	if [[ "$approval_mode" == "unattended" ]]; then
		if ! jq -e --arg pattern "$RELEASE_DEPLOYMENT_PATTERN" \
			--arg recovery_branch "$RELEASE_RECOVERY_BRANCH" '
			(.branch_policies | length) == 2
			and any(.branch_policies[]?; .name == $pattern and .type == "tag")
			and any(.branch_policies[]?; .name == $recovery_branch and .type == "branch")
		' <<<"$deployment_policies" >/dev/null; then
			_release_settings_error "release environment is not limited to v* tags and reviewed main recovery"
			return 1
		fi
	elif ! jq -e --arg pattern "$RELEASE_DEPLOYMENT_PATTERN" '
		(.branch_policies | length) == 1
		and any(.branch_policies[]?; .name == $pattern and .type == "tag")
	' <<<"$deployment_policies" >/dev/null; then
		_release_settings_error "release environment is not limited to the v* tag policy"
		return 1
	fi
	return 0
}

_release_settings_verify_command() {
	local repo_slug=""
	local release_author=""
	local -a reviewers=()
	local unattended=0

	while [[ $# -gt 0 ]]; do
		local option="$1"
		shift
		case "$option" in
		--repo)
			local repo_arg="${1:-}"
			repo_slug="$repo_arg"
			shift || true
			;;
		--release-author)
			local author_arg="${1:-}"
			release_author="$author_arg"
			shift || true
			;;
		--reviewer)
			local reviewer_arg="${1:-}"
			reviewers+=("$reviewer_arg")
			shift || true
			;;
		--unattended)
			unattended=1
			;;
		*)
			_release_settings_error "unknown verify option: ${option}"
			return 1
			;;
		esac
	done

	_release_settings_validate_repo "$repo_slug" || return 1
	_release_settings_validate_login "$release_author" || return 1
	if [[ "$unattended" -eq 1 && "${#reviewers[@]}" -gt 0 ]]; then
		_release_settings_error "--unattended and --reviewer are mutually exclusive"
		return 1
	fi
	if [[ "$unattended" -eq 0 && "${#reviewers[@]}" -eq 0 ]]; then
		_release_settings_error "at least one designated --reviewer is required"
		return 1
	fi
	_release_settings_verify_release_author "$repo_slug" "$release_author" || return 1
	_release_settings_verify_actions "$repo_slug" || return 1
	_release_settings_verify_ruleset "$repo_slug" "$release_author" || return 1
	if [[ "$unattended" -eq 1 ]]; then
		_release_settings_verify_environment "$repo_slug" unattended || return 1
	else
		_release_settings_verify_environment "$repo_slug" reviewers "${reviewers[@]}" || return 1
	fi

	printf 'GITHUB_RELEASE_CONTROLS=verified\n'
	printf 'MANUAL_CHECK_REQUIRED=environment_admin_bypass_disabled\n'
	printf 'MANUAL_CHECK_REQUIRED=publisher_workflow_and_environment\n'
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	_release_settings_require_dependencies || return 1
	case "$command" in
	snapshot) _release_settings_snapshot_command "$@" ;;
	verify-github) _release_settings_verify_command "$@" ;;
	help | --help | -h) _release_settings_usage ;;
	*)
		_release_settings_error "unknown command: ${command}"
		_release_settings_usage >&2
		return 1
		;;
	esac
	return $?
}

main "$@"
