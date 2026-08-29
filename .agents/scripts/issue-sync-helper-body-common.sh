#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared validation and hashing primitives for held-issue body synchronization.

[[ -n "${_ISSUE_SYNC_HELPER_BODY_COMMON_LOADED:-}" ]] && return 0
_ISSUE_SYNC_HELPER_BODY_COMMON_LOADED=1

if ! command -v _gh_current_user_allows_repo_write >/dev/null 2>&1; then
	# shellcheck source=shared-gh-collaborator-permission.sh
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/shared-gh-collaborator-permission.sh"
fi

_BODY_SYNC_SENTINEL="Synced from TODO.md by issue-sync-helper.sh"

_body_sync_canonical_body() {
	local body="$1"
	printf '%s' "$body" | awk '
		{
			sub(/\r$/, "")
			if ($0 ~ /^<!-- aidevops:sig -->[[:space:]]*$/) exit
			lines[NR] = $0
			if ($0 !~ /^[[:space:]]*$/) last = NR
		}
		END {
			for (i = 1; i <= last; i++) {
				printf "%s", lines[i]
				if (i < last) printf "\n"
			}
		}'
	return 0
}

_body_sync_hash_body() {
	local body="$1"
	local digest=""
	if command -v shasum >/dev/null 2>&1; then
		digest=$(_body_sync_canonical_body "$body" | shasum -a 256 | cut -d' ' -f1) || return 1
		printf '%s\n' "$digest"
		return 0
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(_body_sync_canonical_body "$body" | sha256sum | cut -d' ' -f1) || return 1
		printf '%s\n' "$digest"
		return 0
	fi
	print_error "Held body sync requires a SHA-256 tool"
	return 1
}

_body_sync_temp_file() {
	local suffix="$1"
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$temp_root" || return 1
	chmod 700 "$temp_root" 2>/dev/null || true
	mktemp "${temp_root}/held-body-sync-${suffix}-XXXXXX"
	return $?
}

_body_sync_fetch_state() {
	local repo="$1"
	local issue_number="$2"
	gh issue view "$issue_number" --repo "$repo" \
		--json number,title,body,labels,assignees,state,updatedAt 2>/dev/null
	return $?
}

_body_sync_validate_state() {
	local state_json="$1"
	local issue_number="$2"
	jq -e --argjson issue "$issue_number" --arg string_type "string" '
		type == "object" and .number == $issue and
		(.title | type == $string_type) and (.body | type == $string_type) and
		(.updatedAt | type == $string_type) and
		(.state == "OPEN" or .state == "CLOSED") and
		(.labels | type == "array") and all(.labels[]; .name | type == $string_type) and
		(.assignees | type == "array") and all(.assignees[]; .login | type == $string_type)
	' <<<"$state_json" >/dev/null 2>&1
	return $?
}

_body_sync_state_digest() {
	local state_json="$1"
	printf '%s' "$state_json" | jq -Sc '{number,title,body,state,updatedAt,
		labels: ([.labels[].name] | sort), assignees: ([.assignees[].login] | sort)}'
	return $?
}

_body_sync_metadata_digest() {
	local state_json="$1"
	printf '%s' "$state_json" | jq -Sc '{number,title,state,
		labels: ([.labels[].name] | sort), assignees: ([.assignees[].login] | sort)}'
	return $?
}

_body_sync_has_hold() {
	local state_json="$1"
	jq -e 'any(.labels[]; .name == "no-auto-dispatch")' <<<"$state_json" >/dev/null 2>&1
	return $?
}

_body_sync_has_nonself_claim() {
	local state_json="$1"
	local self_login="$2"
	jq -e --arg self "$self_login" '
		([.labels[].name] as $labels |
		 any($labels[]; . == "status:queued" or . == "status:in-progress" or
			 . == "status:in-review" or . == "status:claimed" or
			 . == "consolidation-in-progress") or
		 ((any($labels[]; . == "origin:interactive")) and
		  (all($labels[]; . != "auto-dispatch")))) and
		any(.assignees[]; .login != $self)
	' <<<"$state_json" >/dev/null 2>&1
	return $?
}

_body_sync_scan_file() {
	local body_file="$1"
	local body_role="${2:-body}"
	local scanner="${BODY_SYNC_PROMPT_SCANNER:-${SCRIPT_DIR}/prompt-guard-helper.sh}"
	local scan_status=0
	[[ -x "$scanner" ]] || {
		print_error "Held body sync cannot verify the ${body_role} body in ${body_file}: prompt scanner unavailable"
		return 1
	}
	PROMPT_GUARD_POLICY="${BODY_SYNC_PROMPT_SCANNER_POLICY:-moderate}" \
		PROMPT_GUARD_QUIET=true "$scanner" check-file "$body_file" >/dev/null || scan_status=$?
	#aidevops:trust-boundary -- only the scanner's documented below-threshold
	# warning status is non-blocking; blocks, matcher errors, and unknown statuses
	# continue to fail closed before any issue-body mutation.
	case "$scan_status" in
	0) return 0 ;;
	2)
		print_info "Held body sync observed a below-threshold ${body_role}-body prompt warning under ${BODY_SYNC_PROMPT_SCANNER_POLICY:-moderate} policy"
		return 0
		;;
	*)
		print_error "Held body sync blocked by ${body_role}-body prompt-injection scan for ${body_file}"
		return 1
		;;
	esac
}

_body_sync_validate_authoritative_body() {
	local task_id="$1"
	local project_root="$2"
	local body="$3"
	local brief_file="${project_root}/todo/tasks/${task_id}-brief.md"
	local brief_bytes=0
	[[ -f "$brief_file" ]] || {
		print_error "Held body sync requires an authoritative brief: todo/tasks/${task_id}-brief.md"
		return 1
	}
	brief_bytes=$(wc -c <"$brief_file" | tr -d '[:space:]') || return 1
	[[ "$brief_bytes" =~ ^[0-9]+$ && "$brief_bytes" -ge 100 ]] || {
		print_error "Held body sync refused a stub brief for $task_id"
		return 1
	}
	[[ ${#body} -ge 200 && "$body" == *"## Task Brief"* && "$body" == *"$_BODY_SYNC_SENTINEL"* ]] || {
		print_error "Held body sync refused a non-authoritative or stub composed body for $task_id"
		return 1
	}
	return 0
}
