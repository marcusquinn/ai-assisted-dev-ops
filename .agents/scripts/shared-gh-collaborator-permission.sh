#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GitHub collaborator permission lookup helper
# =============================================================================

[[ -n "${_SHARED_GH_COLLABORATOR_PERMISSION_LOADED:-}" ]] && return 0
_SHARED_GH_COLLABORATOR_PERMISSION_LOADED=1

_AIDEVOPS_GH_PERMISSION_UNKNOWN_VALUE="unknown"

#######################################
# Decide whether an issue actor has maintainer-equivalent repository authority.
#
# OWNER and MEMBER are authoritative webhook associations. COLLABORATOR is
# ambiguous because GitHub also emits it for read/triage collaborators, so it
# must be backed by the authenticated per-repository permission endpoint.
# Installation-authenticated REST may report a user-repository owner as
# COLLABORATOR with permission=none; that anomaly receives a second, canonical
# repository-identity check. Other associations are confirmed non-maintainer
# inputs and do not spend an additional API request.
#
# Globals written:
#   AIDEVOPS_GH_ACTOR_AUTHORITY_LEVEL
#   AIDEVOPS_GH_ACTOR_AUTHORITY_REASON
#
# Args: $1=repo_slug owner/repo, $2=user login, $3=author association
# Returns: 0=trusted, 1=confirmed untrusted, 2=lookup/argument failure.
#######################################
_gh_actor_has_repo_write_authority() {
	local repo_slug="$1"
	local user="$2"
	local association="${3:-NONE}"
	local permission_value=""
	local repo_owner="${repo_slug%%/*}"

	AIDEVOPS_GH_ACTOR_AUTHORITY_LEVEL="$_AIDEVOPS_GH_PERMISSION_UNKNOWN_VALUE"
	AIDEVOPS_GH_ACTOR_AUTHORITY_REASON="$_AIDEVOPS_GH_PERMISSION_UNKNOWN_VALUE"
	export AIDEVOPS_GH_ACTOR_AUTHORITY_LEVEL AIDEVOPS_GH_ACTOR_AUTHORITY_REASON

	#aidevops:trust-boundary -- bare COLLABORATOR must never authorize worker input.
	case "$association" in
	OWNER | MEMBER)
		AIDEVOPS_GH_ACTOR_AUTHORITY_LEVEL="$association"
		AIDEVOPS_GH_ACTOR_AUTHORITY_REASON="trusted-association"
		export AIDEVOPS_GH_ACTOR_AUTHORITY_LEVEL AIDEVOPS_GH_ACTOR_AUTHORITY_REASON
		return 0
		;;
	COLLABORATOR)
		if [[ -z "$repo_slug" || -z "$user" ]]; then
			AIDEVOPS_GH_ACTOR_AUTHORITY_REASON="missing-collaborator-identity"
			export AIDEVOPS_GH_ACTOR_AUTHORITY_REASON
			return 2
		fi
		if ! _gh_collaborator_permission_lookup "$repo_slug" "$user" permission_value; then
			AIDEVOPS_GH_ACTOR_AUTHORITY_REASON="permission-lookup-failed:${AIDEVOPS_GH_COLLAB_PERMISSION_REASON:-$_AIDEVOPS_GH_PERMISSION_UNKNOWN_VALUE}"
			export AIDEVOPS_GH_ACTOR_AUTHORITY_REASON
			return 2
		fi
		AIDEVOPS_GH_ACTOR_AUTHORITY_LEVEL="$permission_value"
		export AIDEVOPS_GH_ACTOR_AUTHORITY_LEVEL
		case "$permission_value" in
		admin | maintain | write)
			AIDEVOPS_GH_ACTOR_AUTHORITY_REASON="trusted-permission"
			export AIDEVOPS_GH_ACTOR_AUTHORITY_REASON
			return 0
			;;
		*)
			#aidevops:trust-boundary -- login/slug text alone is not authority.
			# Require canonical repository metadata before repairing the known
			# installation-auth owner anomaly.
			local user_lower="" repo_owner_lower=""
			user_lower=$(printf '%s' "$user" | tr '[:upper:]' '[:lower:]')
			repo_owner_lower=$(printf '%s' "$repo_owner" | tr '[:upper:]' '[:lower:]')
			if [[ "$user_lower" == "$repo_owner_lower" ]]; then
				local repository_owner_rc=0
				_gh_repository_owner_matches_actor "$repo_slug" "$user" || repository_owner_rc=$?
				if [[ "$repository_owner_rc" -eq 0 ]]; then
					AIDEVOPS_GH_ACTOR_AUTHORITY_LEVEL="OWNER"
					AIDEVOPS_GH_ACTOR_AUTHORITY_REASON="trusted-repository-owner"
					export AIDEVOPS_GH_ACTOR_AUTHORITY_LEVEL AIDEVOPS_GH_ACTOR_AUTHORITY_REASON
					return 0
				fi
				if [[ "$repository_owner_rc" -eq 2 ]]; then
					AIDEVOPS_GH_ACTOR_AUTHORITY_REASON="repository-owner-lookup-failed:${AIDEVOPS_GH_REPO_OWNER_REASON:-$_AIDEVOPS_GH_PERMISSION_UNKNOWN_VALUE}"
					export AIDEVOPS_GH_ACTOR_AUTHORITY_REASON
					return 2
				fi
			fi
			AIDEVOPS_GH_ACTOR_AUTHORITY_REASON="insufficient-permission:${permission_value:-none}"
			export AIDEVOPS_GH_ACTOR_AUTHORITY_REASON
			return 1
			;;
		esac
		;;
	*)
		AIDEVOPS_GH_ACTOR_AUTHORITY_REASON="untrusted-association:${association:-NONE}"
		export AIDEVOPS_GH_ACTOR_AUTHORITY_REASON
		return 1
		;;
	esac

	return 1
}

#######################################
# Verify that an actor is the current owner of a canonical user repository.
#
# A matching slug prefix is only a candidate signal: repositories can be
# transferred or renamed and old REST paths may redirect. This check requires
# the response's canonical full_name to equal the requested slug and its owner
# to be a User whose current login exactly matches the issue actor.
#
# Globals written:
#   AIDEVOPS_GH_REPO_OWNER_REASON
#
# Args: $1=repo_slug owner/repo, $2=actor login
# Returns: 0=owner match, 1=canonical non-match, 2=lookup/argument failure.
#######################################
_gh_repository_owner_matches_actor() {
	local repo_slug="$1"
	local user="$2"
	local repository_json=""
	local repository_identity=""
	local canonical_slug=""
	local owner_login=""
	local owner_type=""
	local requested_slug_lower=""
	local canonical_slug_lower=""
	local user_lower=""
	local owner_login_lower=""

	AIDEVOPS_GH_REPO_OWNER_REASON="$_AIDEVOPS_GH_PERMISSION_UNKNOWN_VALUE"
	export AIDEVOPS_GH_REPO_OWNER_REASON

	if [[ ! "$repo_slug" =~ ^[^/]+/[^/]+$ || -z "$user" ]]; then
		AIDEVOPS_GH_REPO_OWNER_REASON="invalid-repository-identity"
		export AIDEVOPS_GH_REPO_OWNER_REASON
		return 2
	fi
	if ! declare -F _rest_api_call >/dev/null 2>&1; then
		AIDEVOPS_GH_REPO_OWNER_REASON="rest-helper-unavailable"
		export AIDEVOPS_GH_REPO_OWNER_REASON
		return 2
	fi

	repository_json=$(AIDEVOPS_GH_QUOTA_COST=1 \
		AIDEVOPS_GH_ROUTE_DECISION="repository-owner-identity-rest" \
		_rest_api_call read gh api "/repos/${repo_slug}" 2>/dev/null) || repository_json=""
	if [[ -z "$repository_json" ]]; then
		AIDEVOPS_GH_REPO_OWNER_REASON="api-failure"
		export AIDEVOPS_GH_REPO_OWNER_REASON
		return 2
	fi

	repository_identity=$(printf '%s' "$repository_json" | jq -r \
		'[.full_name // "", .owner.login // "", .owner.type // ""] | @tsv' 2>/dev/null) || repository_identity=""
	IFS=$'\t' read -r canonical_slug owner_login owner_type <<<"$repository_identity"
	if [[ -z "$canonical_slug" || -z "$owner_login" || -z "$owner_type" ]]; then
		AIDEVOPS_GH_REPO_OWNER_REASON="malformed-response"
		export AIDEVOPS_GH_REPO_OWNER_REASON
		return 2
	fi
	requested_slug_lower=$(printf '%s' "$repo_slug" | tr '[:upper:]' '[:lower:]')
	canonical_slug_lower=$(printf '%s' "$canonical_slug" | tr '[:upper:]' '[:lower:]')
	user_lower=$(printf '%s' "$user" | tr '[:upper:]' '[:lower:]')
	owner_login_lower=$(printf '%s' "$owner_login" | tr '[:upper:]' '[:lower:]')
	if [[ "$canonical_slug_lower" == "$requested_slug_lower" && "$owner_login_lower" == "$user_lower" && "$owner_type" == "User" ]]; then
		AIDEVOPS_GH_REPO_OWNER_REASON="matched"
		export AIDEVOPS_GH_REPO_OWNER_REASON
		return 0
	fi

	AIDEVOPS_GH_REPO_OWNER_REASON="canonical-owner-mismatch"
	export AIDEVOPS_GH_REPO_OWNER_REASON
	return 1
}

#######################################
# Look up a repository collaborator permission through App-aware REST routing.
#
# Auth selection stays in _rest_api_call/github_app_api_call: GitHub App
# installation auth is preferred when configured, with normal gh/PAT fallback.
# Callers can inspect the status globals after a non-zero return to distinguish
# transient lookup failures from confirmed non-collaborators.
#
# Globals written:
#   AIDEVOPS_GH_COLLAB_PERMISSION_HTTP
#   AIDEVOPS_GH_COLLAB_PERMISSION_REASON
#
# Args: $1=repo_slug owner/repo, $2=user login, $3=optional output variable
# Output: permission value (admin|maintain|write|triage|read|none) on lookup success.
# Returns: 0=lookup succeeded (404 maps to none), 2=lookup/API/parse failure.
#######################################
_gh_collaborator_permission_lookup() {
	local repo_slug="$1"
	local user="$2"
	local out_var="${3:-}"
	local perm_url="/repos/${repo_slug}/collaborators/${user}/permission"
	local api_response=""
	local rc=0
	local http_status=""
	local line=""
	local body=""
	local in_body=0
	# Keep the internal value distinct from caller-selected output names. Bash
	# uses dynamic scope, so a local named permission_value would shadow the
	# common caller output variable and silently return an empty permission.
	local resolved_permission=""

	AIDEVOPS_GH_COLLAB_PERMISSION_HTTP="$_AIDEVOPS_GH_PERMISSION_UNKNOWN_VALUE"
	AIDEVOPS_GH_COLLAB_PERMISSION_REASON="$_AIDEVOPS_GH_PERMISSION_UNKNOWN_VALUE"
	export AIDEVOPS_GH_COLLAB_PERMISSION_HTTP AIDEVOPS_GH_COLLAB_PERMISSION_REASON

	if [[ -z "$repo_slug" || -z "$user" ]]; then
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="missing-argument"
		export AIDEVOPS_GH_COLLAB_PERMISSION_REASON
		return 2
	fi

	api_response=$(AIDEVOPS_GH_QUOTA_COST=1 \
		AIDEVOPS_GH_ROUTE_DECISION="collaborator-permission-rest" \
		_rest_api_call read gh api -i "$perm_url" 2>&1)
	rc=$?
	while IFS= read -r line; do
		line="${line%$'\r'}"
		case "$line" in
		HTTP/*)
			http_status="${line#* }"
			http_status="${http_status%% *}"
			;;
		"")
			in_body=1
			;;
		\{* | \[*)
			in_body=1
			body="${body}${line}"$'\n'
			;;
		*)
			if [[ "$in_body" -eq 1 ]]; then
				body="${body}${line}"$'\n'
			fi
			;;
		esac
	done <<<"$api_response"

	[[ -n "$http_status" ]] && AIDEVOPS_GH_COLLAB_PERMISSION_HTTP="$http_status"
	export AIDEVOPS_GH_COLLAB_PERMISSION_HTTP

	if [[ "$http_status" == "404" ]]; then
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="not-collaborator"
		export AIDEVOPS_GH_COLLAB_PERMISSION_REASON
		if [[ -n "$out_var" ]]; then
			printf -v "$out_var" '%s' "none"
		else
			printf '%s\n' "none"
		fi
		return 0
	fi

	if [[ "$rc" -ne 0 ]]; then
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="api-failure"
		export AIDEVOPS_GH_COLLAB_PERMISSION_REASON
		return 2
	fi

	if [[ "$http_status" != "200" ]]; then
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="unexpected-http"
		export AIDEVOPS_GH_COLLAB_PERMISSION_REASON
		return 2
	fi

	resolved_permission=$(printf '%s' "$body" | jq -r '.permission // .role_name // ""' 2>/dev/null) || resolved_permission=""
	if [[ -z "$resolved_permission" ]]; then
		resolved_permission=$(printf '%s' "$api_response" | sed -nE 's/^[[:space:]]*\{?[[:space:]]*"(permission|role_name)"[[:space:]]*:[[:space:]]*"(admin|maintain|write|triage|read|none)".*/\2/p' | tail -1) || resolved_permission=""
	fi
	case "$resolved_permission" in
	admin | maintain | write | triage | read | none)
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="ok"
		export AIDEVOPS_GH_COLLAB_PERMISSION_REASON
		if [[ -n "$out_var" ]]; then
			printf -v "$out_var" '%s' "$resolved_permission"
		else
			printf '%s\n' "$resolved_permission"
		fi
		return 0
		;;
	*)
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="malformed-response"
		export AIDEVOPS_GH_COLLAB_PERMISSION_REASON
		return 2
		;;
	esac
}

#######################################
# Verify the authenticated GitHub user may write repo state.
#
# Public issue comments can succeed for non-collaborators, so callers must not
# infer authorization from a successful write. This guard checks the current
# auth identity against the collaborator permission API before any automated
# comment, close, label, approval, merge, or dispatch claim.
#
# Globals written:
#   AIDEVOPS_GH_WRITE_PERMISSION_USER
#   AIDEVOPS_GH_WRITE_PERMISSION_LEVEL
#   AIDEVOPS_GH_WRITE_PERMISSION_REASON
#
# Args: $1=repo_slug owner/repo
# Returns: 0=admin/maintain/write, 1=read/triage/none/unknown/failure.
#######################################
_gh_current_user_allows_repo_write() {
	local repo_slug="$1"
	local current_user=""
	local current_permission=""

	AIDEVOPS_GH_WRITE_PERMISSION_USER=""
	AIDEVOPS_GH_WRITE_PERMISSION_LEVEL="$_AIDEVOPS_GH_PERMISSION_UNKNOWN_VALUE"
	AIDEVOPS_GH_WRITE_PERMISSION_REASON="$_AIDEVOPS_GH_PERMISSION_UNKNOWN_VALUE"
	export AIDEVOPS_GH_WRITE_PERMISSION_USER AIDEVOPS_GH_WRITE_PERMISSION_LEVEL AIDEVOPS_GH_WRITE_PERMISSION_REASON

	if [[ -z "$repo_slug" ]]; then
		AIDEVOPS_GH_WRITE_PERMISSION_REASON="missing-repo"
		export AIDEVOPS_GH_WRITE_PERMISSION_REASON
		return 1
	fi

	# #aidevops:trust-boundary — do not cache this lookup. Long-running pulse
	# sessions can rotate GH_TOKEN/OAuth accounts between writes; a stale owner
	# login would authorize a later non-collaborator token.
	current_user=$(gh api user --jq '.login // ""') || current_user=""
	AIDEVOPS_GH_WRITE_PERMISSION_USER="$current_user"
	export AIDEVOPS_GH_WRITE_PERMISSION_USER
	if [[ -z "$current_user" ]]; then
		AIDEVOPS_GH_WRITE_PERMISSION_REASON="current-user-lookup-failed"
		export AIDEVOPS_GH_WRITE_PERMISSION_REASON
		return 1
	fi

	if ! _gh_collaborator_permission_lookup "$repo_slug" "$current_user" current_permission; then
		AIDEVOPS_GH_WRITE_PERMISSION_LEVEL="$_AIDEVOPS_GH_PERMISSION_UNKNOWN_VALUE"
		AIDEVOPS_GH_WRITE_PERMISSION_REASON="permission-lookup-failed:${AIDEVOPS_GH_COLLAB_PERMISSION_REASON:-$_AIDEVOPS_GH_PERMISSION_UNKNOWN_VALUE}"
		export AIDEVOPS_GH_WRITE_PERMISSION_LEVEL AIDEVOPS_GH_WRITE_PERMISSION_REASON
		return 1
	fi

	AIDEVOPS_GH_WRITE_PERMISSION_LEVEL="$current_permission"
	export AIDEVOPS_GH_WRITE_PERMISSION_LEVEL
	case "$current_permission" in
	admin | maintain | write)
		AIDEVOPS_GH_WRITE_PERMISSION_REASON="allowed"
		export AIDEVOPS_GH_WRITE_PERMISSION_REASON
		return 0
		;;
	*)
		AIDEVOPS_GH_WRITE_PERMISSION_REASON="insufficient-permission:${current_permission:-none}"
		export AIDEVOPS_GH_WRITE_PERMISSION_REASON
		return 1
		;;
	esac
}
