#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# approval-helper-permissions.sh — Scoped worker-permission approval domain.
# =============================================================================
# Sourced by approval-helper.sh. Preserves permission request validation, signed
# grant persistence, telemetry, and verification behind the original CLI.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_APPROVAL_HELPER_PERMISSIONS_LOADED:-}" ]] && return 0
_APPROVAL_HELPER_PERMISSIONS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_permission_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_permission_lib_path" == "${BASH_SOURCE[0]}" ]] && _permission_lib_path="."
	SCRIPT_DIR="$(cd "$_permission_lib_path" && pwd)"
	unset _permission_lib_path
fi

readonly PERMISSION_REQUEST_MARKER="<!-- aidevops-permission-request -->"
readonly PERMISSION_GRANT_MARKER="<!-- aidevops-signed-permission-grant -->"
readonly PERMISSION_REQUEST_SCHEMA="aidevops-permission-request/v1"
readonly PERMISSION_GRANT_SCHEMA="aidevops-permission-grant/v1"
readonly PERMISSION_SHA256_PATTERN='^[0-9a-f]{64}$'
readonly PERMISSION_JSON_ARRAY_TYPE="array"
readonly PERMISSION_JSON_STRING_TYPE="string"
readonly _PERMISSION_TARGET_ISSUE="issue"
readonly _PERMISSION_BLOCKER_STATUS="blocked"
readonly _PERMISSION_BLOCKER_TRUE="true"
readonly _PERMISSION_APPROVAL_REJECTED_EVENT="permission_approval_rejected"
readonly _PERMISSION_GRANT_PERSISTENCE_FAILED_EVENT="permission_grant_persistence_failed"

_run_worker_blocker_logger() {
	local logger="$1"
	shift
	local node_bin
	node_bin=$(command -v node) || return 0
	if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]]; then
		command -v sudo >/dev/null 2>&1 || return 0
		sudo -u "$SUDO_USER" -H -- "$node_bin" "$logger" "$@" >/dev/null 2>&1 || true
		return 0
	fi
	"$node_bin" "$logger" "$@" >/dev/null 2>&1 || true
	return 0
}

_record_permission_blocker_event() {
	local event="$1"
	local status="$2"
	local reason="$3"
	local blocking="$4"
	local target_number="$5"
	local slug="$6"
	local request_id="$7"
	local session_key="${8:-}"
	local detail="${9:-}"
	local logger="${SCRIPT_DIR}/worker-blocker-log.mjs"
	local log_file="${AIDEVOPS_WORKER_BLOCKER_LOG_FILE:-${_APPROVAL_HOME}/.aidevops/logs/worker-progress-blockers.jsonl}"
	[[ -f "$logger" ]] || return 0
	_run_worker_blocker_logger "$logger" append \
		--event "$event" \
		--status "$status" \
		--reason "$reason" \
		--blocking "$blocking" \
		--source "approval-helper" \
		--issue-number "$target_number" \
		--repo-slug "$slug" \
		--request-id "$request_id" \
		--session-key "$session_key" \
		--detail "$detail" \
		--log-file "$log_file"
	return 0
}

_record_permission_approval_rejection() {
	local reason="$1"
	local target_number="$2"
	local slug="$3"
	local request_id="$4"
	local session_key="$5"
	local detail="$6"
	_record_permission_blocker_event "$_PERMISSION_APPROVAL_REJECTED_EVENT" "$_PERMISSION_BLOCKER_STATUS" \
		"$reason" "$_PERMISSION_BLOCKER_TRUE" "$target_number" "$slug" "$request_id" "$session_key" "$detail"
	return 0
}

_record_permission_grant_failure() {
	local reason="$1"
	local target_number="$2"
	local slug="$3"
	local request_id="$4"
	local session_key="$5"
	local detail="$6"
	_record_permission_blocker_event "$_PERMISSION_GRANT_PERSISTENCE_FAILED_EVENT" "$_PERMISSION_BLOCKER_STATUS" \
		"$reason" "$_PERMISSION_BLOCKER_TRUE" "$target_number" "$slug" "$request_id" "$session_key" "$detail"
	return 0
}

_permission_request_session() {
	local request_json="$1"
	jq -r '.worker.session // empty' <<<"$request_json"
	return $?
}

_extract_tilde_fenced_block() {
	local body="$1"
	printf '%s\n' "$body" | awk '
		/^~~~/ {
			if (inside) { exit }
			inside = 1
			next
		}
		inside { print }
	'
	return 0
}

_permission_request_digest() {
	local request_json="$1"
	local canonical_file
	canonical_file=$(mktemp)
	jq -cS 'del(.request_id, .request_sha256)' <<<"$request_json" >"$canonical_file" || {
		rm -f "$canonical_file"
		return 1
	}
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$canonical_file" | awk '{print $1}'
	else
		sha256sum "$canonical_file" | awk '{print $1}'
	fi
	rm -f "$canonical_file"
	return 0
}

_permission_grant_expiry() {
	if date -u -v+4H +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
		date -u -v+4H +%Y-%m-%dT%H:%M:%SZ
	else
		date -u -d '+4 hours' +%Y-%m-%dT%H:%M:%SZ
	fi
	return 0
}

_trusted_permission_comments_json() {
	local pages="$1"
	jq -c --arg array_type "$PERMISSION_JSON_ARRAY_TYPE" '
		(if type == $array_type and all(.[]; type == $array_type) then [.[][]?] else [.[]?] end)
		| [ .[] | select(
			(.author_association // "") as $association
			| ["OWNER", "MEMBER", "COLLABORATOR"] | index($association) != null
		) ]
	' <<<"$pages"
	return $?
}

_fetch_permission_request_json() {
	local target_number="$1"
	local slug="$2"
	local request_id="$3"
	local pages comments body endpoint
	endpoint=$(_permission_comments_endpoint "$slug" "$target_number")
	pages=$(gh api "$endpoint" --paginate --slurp 2>/dev/null) || return 1
	comments=$(_trusted_permission_comments_json "$pages") || return 1
	body=$(jq -r --arg marker "$PERMISSION_REQUEST_MARKER" --arg request "$request_id" '
		[.[] | select((.body // "") | contains($marker) and contains($request))]
		| sort_by(.id) | last | .body // ""
	' <<<"$comments") || return 1
	[[ -n "$body" ]] || return 1
	_extract_tilde_fenced_block "$body"
	return 0
}

_fetch_latest_permission_request_json() {
	local target_number="$1"
	local slug="$2"
	local pages comments body endpoint
	endpoint=$(_permission_comments_endpoint "$slug" "$target_number")
	pages=$(gh api "$endpoint" --paginate --slurp 2>/dev/null) || return 1
	comments=$(_trusted_permission_comments_json "$pages") || return 1
	body=$(jq -r --arg marker "$PERMISSION_REQUEST_MARKER" '
		[.[] | select((.body // "") | contains($marker))]
		| sort_by(.id) | last | .body // ""
	' <<<"$comments") || return 1
	[[ -n "$body" ]] || return 1
	_extract_tilde_fenced_block "$body"
	return 0
}

_validate_permission_request_json() {
	local request_json="$1"
	local target_type="$2"
	local target_number="$3"
	local slug="$4"
	local request_id="$5"
	local normalized_slug digest expected_digest
	normalized_slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
	jq -e --arg schema "$PERMISSION_REQUEST_SCHEMA" --arg type "$target_type" \
		--arg number "$target_number" --arg repo "$normalized_slug" --arg request "$request_id" \
		--arg sha_pattern "$PERMISSION_SHA256_PATTERN" --arg array_type "$PERMISSION_JSON_ARRAY_TYPE" \
		--arg string_type "$PERMISSION_JSON_STRING_TYPE" '
		.schema == $schema
		and .target.kind == $type
		and (.target.number | tostring) == $number
		and .target.repository == $repo
		and .request_id == $request
		and (.request_sha256 | type == $string_type and test($sha_pattern))
		and (.worker.worktree_sha256 | type == $string_type and test($sha_pattern))
		and (.capabilities | type == $array_type and length > 0 and length <= 20)
		and all(.capabilities[];
			(.permission as $permission | ["bash", "external_directory"] | index($permission) != null)
			and (.patterns | type == $array_type and length > 0 and length <= 20)
			and all(.patterns[]; type == $string_type and length <= 500)
			and .risk.grantable == true
			and all(.patterns[]?;
				(test("(?i)(approval-keys/private|/(\\.ssh|\\.gnupg|\\.aws|\\.azure|\\.kube)(/|$)|/(\\.config/(gh|gcloud|glab-cli|hub)|\\.docker)(/|$)|/(\\.netrc|\\.npmrc|\\.pypirc|\\.git-credentials)($|\\*)|auth\\.json($|\\*)|credentials?([./]|$)|(^|/)\\.env([./]|$))") | not)
				and (test("^(\\*|\\*\\*|/\\*\\*|~/\\*\\*|\\$WORKTREE/\\*\\*)$") | not)
			)
		)
	' <<<"$request_json" >/dev/null || return 1
	digest=$(_permission_request_digest "$request_json") || return 1
	expected_digest=$(jq -r '.request_sha256' <<<"$request_json")
	[[ "$digest" == "$expected_digest" ]] || return 1
	[[ "$request_id" == "perm-${digest:0:16}" ]] || return 1
	return 0
}

_permission_request_is_latest() {
	local request_json="$1"
	local target_number="$2"
	local slug="$3"
	local latest_json latest_id latest_digest expected_id expected_digest
	latest_json=$(_fetch_latest_permission_request_json "$target_number" "$slug") || return 1
	latest_id=$(jq -r '.request_id // ""' \
		<<<"$latest_json")
	latest_digest=$(jq -r '.request_sha256 // ""' \
		<<<"$latest_json")
	expected_id=$(jq -r '.request_id // ""' \
		<<<"$request_json")
	expected_digest=$(jq -r '.request_sha256 // ""' \
		<<<"$request_json")
	[[ "$latest_id" == "$expected_id" && "$latest_digest" == "$expected_digest" ]]
	return $?
}

_confirm_permission_approval() {
	local request_json="$1"
	local target_type="$2"
	local target_number="$3"
	local slug="$4"
	echo ""
	echo "Approving scoped worker permissions:"
	echo "  Target:  ${target_type} #${target_number}"
	echo "  Repo:    ${slug}"
	echo "  Request: $(jq -r '.request_id' <<<"$request_json")"
	echo "  Session: $(jq -r '.worker.session' <<<"$request_json")"
	echo "  Branch:  $(jq -r '.worker.branch' <<<"$request_json")"
	echo "  Worktree binding: $(jq -r '.worker.worktree_sha256[0:16]' <<<"$request_json")..."
	echo "  Expires: 4 hours after signing"
	echo ""
	jq -r '.capabilities[] | "  - [" + (.risk.level | ascii_upcase) + "] " + .permission + " via " + .tool + ": " + (if (.patterns | length) == 0 then "(no pattern)" else (.patterns | join(", ")) end)' <<<"$request_json"
	echo ""
	printf "Type APPROVE to confirm these exact capabilities: "
	local confirmation=""
	read -r confirmation
	[[ "$confirmation" == "APPROVE" ]] || {
		_print_error "Permission approval cancelled"
		return 1
	}
	return 0
}

_build_permission_grant_comment() {
	local payload="$1"
	local sig_file="$2"
	local signature
	signature=$(<"$sig_file")
	cat <<EOF
${PERMISSION_GRANT_MARKER}
## Worker permission grant (cryptographically signed)

\`\`\`
${payload}
\`\`\`

\`\`\`
${signature}
\`\`\`

This grant authorizes only the embedded capabilities, target, request digest, and expiry. It does not approve issue scope or merge/release.
EOF
	return 0
}

_permission_grant_path() {
	local slug="$1"
	local target_number="$2"
	local safe_slug
	safe_slug=$(printf '%s' "$slug" | tr '/:' '__')
	printf '%s/.aidevops/permission-grants/%s/%s.json' "$_APPROVAL_HOME" "$safe_slug" "$target_number"
	return 0
}

_set_permission_grant_owner() {
	local real_user="$1"
	local grant_path="$2"
	[[ "$(id -u)" -eq 0 ]] || return 0
	chown "$real_user" "$grant_path" 2>/dev/null || return 1
	return 0
}

_write_local_permission_grant() {
	local payload="$1"
	local sig_file="$2"
	local slug="$3"
	local target_number="$4"
	local grant_path grant_tmp real_user
	grant_path=$(_permission_grant_path "$slug" "$target_number")
	grant_tmp=$(mktemp) || return 1
	real_user=$(_approval_real_user)
	if ! jq -n --arg payload "$payload" --rawfile signature "$sig_file" \
		'{payload: $payload, signature: $signature}' >"$grant_tmp"; then
		rm -f "$grant_tmp"
		return 1
	fi
	if ! mkdir -p "$(dirname "$grant_path")"; then
		rm -f "$grant_tmp"
		return 1
	fi
	if ! install -m 600 "$grant_tmp" "$grant_path"; then
		rm -f "$grant_tmp"
		return 1
	fi
	if ! _set_permission_grant_owner "$real_user" "$grant_path"; then
		rm -f "$grant_tmp" "$grant_path" || true
		return 1
	fi
	rm -f "$grant_tmp"
	return 0
}

_apply_permission_approval_state() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local request_json="$4"
	if [[ "$target_type" == "$_PERMISSION_TARGET_ISSUE" ]]; then
		local issue_json labels_csv resume_auto
		issue_json=$(gh_issue_view "$target_number" --repo "$slug" --json labels 2>/dev/null) || return 1
		labels_csv=$(jq -r '(.labels // []) | map(.name) | join(",")' <<<"$issue_json") || return 1
		resume_auto=$(jq -r '.context.resume_auto_dispatch == true' <<<"$request_json") || return 1
		local -a edit_args=(--remove-label "needs-maintainer-permissions")
		if [[ ",${labels_csv}," != *",status:blocked,"* ]]; then
			edit_args+=(--add-label "status:available")
		fi
		if [[ "$resume_auto" == "true" ]]; then
			edit_args+=(--add-label "$_APPROVAL_AUTO_DISPATCH_LABEL")
		fi
		gh_issue_edit_safe "$target_number" --repo "$slug" "${edit_args[@]}" >/dev/null || return 1
	else
		gh pr edit "$target_number" --repo "$slug" --remove-label "needs-maintainer-permissions" >/dev/null || return 1
	fi
	return 0
}

_kick_pulse_after_permission_approval() {
	local pulse_wrapper="${_APPROVAL_HOME}/.aidevops/agents/scripts/pulse-wrapper.sh"
	local kick_log="${_APPROVAL_HOME}/.aidevops/logs/pulse-approve-kick.log"
	[[ -x "$pulse_wrapper" ]] || return 0
	mkdir -p "$(dirname "$kick_log")" 2>/dev/null || true
	if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]] && command -v sudo >/dev/null 2>&1; then
		(
			nohup sudo -u "$SUDO_USER" -H -- "$pulse_wrapper" >>"$kick_log" 2>&1 </dev/null &
			disown 2>/dev/null || true
		) 2>/dev/null
	else
		(
			nohup "$pulse_wrapper" >>"$kick_log" 2>&1 </dev/null &
			disown 2>/dev/null || true
		) 2>/dev/null
	fi
	return 0
}

_persist_signed_permission_grant() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local request_id="$4"
	local request_json="$5"
	local payload="$6"
	local sig_file="$7"
	local expires_at="$8"
	local worker_session="${9:-}"
	local comment_body
	comment_body=$(_build_permission_grant_comment "$payload" "$sig_file")

	if [[ "$target_type" == "$_PERMISSION_TARGET_ISSUE" ]]; then
		if ! gh_issue_comment "$target_number" --repo "$slug" --body "$comment_body"; then
			rm -f "$sig_file"
			_record_permission_grant_failure "grant_comment_write_failed" "$target_number" "$slug" \
				"$request_id" "$worker_session" "Signed grant comment could not be persisted"
			return 1
		fi
	elif ! gh_pr_comment "$target_number" --repo "$slug" --body "$comment_body"; then
		rm -f "$sig_file"
		_record_permission_grant_failure "grant_comment_write_failed" "$target_number" "$slug" \
			"$request_id" "$worker_session" "Signed grant comment could not be persisted"
		return 1
	fi

	if ! _permission_request_is_latest "$request_json" "$target_number" "$slug"; then
		rm -f "$sig_file"
		_record_permission_approval_rejection "request_superseded_after_signing" "$target_number" "$slug" \
			"$request_id" "$worker_session" "Permission request changed after the signed grant comment was posted"
		_print_error "Permission grant was posted, but the request is no longer latest; dispatch remains blocked"
		return 1
	fi

	if ! _write_local_permission_grant "$payload" "$sig_file" "$slug" "$target_number"; then
		rm -f "$sig_file"
		_record_permission_grant_failure "grant_file_write_failed" "$target_number" "$slug" \
			"$request_id" "$worker_session" "Local signed grant file could not be persisted"
		return 1
	fi
	rm -f "$sig_file"

	if ! _apply_permission_approval_state "$target_type" "$target_number" "$slug" "$request_json"; then
		_record_permission_grant_failure "approval_state_update_failed" "$target_number" "$slug" \
			"$request_id" "$worker_session" "Permission grant exists but the blocking issue state could not be cleared"
		return 1
	fi

	_record_permission_blocker_event "permission_grant_approved" "resuming" \
		"scoped_permission_granted" "false" "$target_number" "$slug" "$request_id" \
		"$worker_session" "Signed permission grant persisted and dispatch block cleared"
	_kick_pulse_after_permission_approval
	_print_ok "Scoped permissions ${request_id} approved for ${target_type} #${target_number} until ${expires_at}"
	return 0
}

cmd_permissions() {
	local target_type="${1:-}"
	local target_number="${2:-}"
	shift 2 2>/dev/null || true
	local slug="" request_id=""
	if [[ $# -gt 0 && "$1" != --* ]]; then
		slug="$1"
		shift
	fi
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--request) request_id="${2:-}"; shift 2 ;;
		*) _print_error "Unknown permissions option: $arg"; return 1 ;;
		esac
	done
	local usage="Usage: sudo aidevops approve permissions issue|pr <number> [owner/repo] --request perm-<id>"
	[[ "$target_type" == "$_PERMISSION_TARGET_ISSUE" || "$target_type" == "pr" ]] || { _print_error "$usage"; return 1; }
	_require_number_arg "$target_number" "$target_type" "$usage" || return 1
	[[ "$request_id" =~ ^perm-[0-9a-f]{16}$ ]] || { _print_error "$usage"; return 1; }
	_require_interactive_root "$usage" || return 1
	local actual_key
	actual_key=$(_approval_private_key_path)
	_require_approval_key "$actual_key" || return 1
	_require_gh_auth || return 1
	slug=$(_resolve_slug_or_fail "$slug" "$usage") || return 1
	_validate_approval_target_kind "$target_type" "$target_number" "$slug" || return 1
	local request_json worker_session
	request_json=$(_fetch_permission_request_json "$target_number" "$slug" "$request_id") || {
		_print_error "Could not find permission request ${request_id} on ${target_type} #${target_number}"
		return 1
	}
	worker_session=$(_permission_request_session "$request_json")
	_validate_permission_request_json "$request_json" "$target_type" "$target_number" "$slug" "$request_id" || {
		_record_permission_approval_rejection "request_invalid_or_non_grantable" "$target_number" "$slug" "$request_id" "" \
			"Permission request was malformed, changed, or contained non-grantable scope"
		_print_error "Permission request is malformed, changed, or contains a non-grantable sensitive capability"
		return 1
	}
	_confirm_permission_approval "$request_json" "$target_type" "$target_number" "$slug" || return 1
	_permission_request_is_latest "$request_json" "$target_number" "$slug" || {
		_record_permission_approval_rejection "request_superseded" "$target_number" "$slug" "$request_id" \
			"$worker_session" \
			"A newer permission request superseded the request under review"
		_print_error "A newer permission request appeared while approval was pending; review and approve the latest request instead"
		return 1
	}
	local issued_at expires_at payload sig_file
	issued_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	expires_at=$(_permission_grant_expiry)
	payload=$(jq -cS --arg schema "$PERMISSION_GRANT_SCHEMA" --arg issued "$issued_at" --arg expires "$expires_at" '
		{
			schema: $schema,
			authority: "worker-permissions",
			target,
			request_id,
			request_sha256,
			worker,
			capabilities,
			issued_at: $issued,
			expires_at: $expires
		}
	' <<<"$request_json") || {
		_record_permission_grant_failure "grant_payload_build_failed" "$target_number" "$slug" "$request_id" \
			"$worker_session" "Signed grant payload could not be built"
		return 1
	}
	sig_file=$(mktemp)
	if ! _sign_approval_payload "$payload" "$actual_key" "$sig_file"; then
		rm -f "$sig_file"
		_record_permission_grant_failure "grant_signing_failed" "$target_number" "$slug" "$request_id" \
			"$worker_session" "Signed grant payload could not be signed"
		return 1
	fi
	_persist_signed_permission_grant "$target_type" "$target_number" "$slug" "$request_id" \
		"$request_json" "$payload" "$sig_file" "$expires_at" "$worker_session"
	return $?
}

_fetch_latest_permission_grant_body() {
	local target_number="$1"
	local slug="$2"
	local request_id="$3"
	local pages comments endpoint
	endpoint=$(_permission_comments_endpoint "$slug" "$target_number")
	pages=$(gh api "$endpoint" --paginate --slurp 2>/dev/null) || return 1
	comments=$(_trusted_permission_comments_json "$pages") || return 1
	jq -r --arg marker "$PERMISSION_GRANT_MARKER" --arg request "$request_id" '
		[.[] | select((.body // "") | contains($marker) and contains($request))]
		| sort_by(.id) | last | .body // ""
	' <<<"$comments"
	return $?
}

_permission_grant_time_valid() {
	local payload="$1"
	python3 - "$payload" <<'PY'
import datetime as dt
import json
import sys

try:
    payload = json.loads(sys.argv[1])
    issued = dt.datetime.fromisoformat(payload["issued_at"].replace("Z", "+00:00"))
    expires = dt.datetime.fromisoformat(payload["expires_at"].replace("Z", "+00:00"))
    now = dt.datetime.now(dt.timezone.utc)
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
valid = issued <= now + dt.timedelta(minutes=5) and expires > now and expires > issued
valid = valid and expires - issued <= dt.timedelta(hours=4)
raise SystemExit(0 if valid else 1)
PY
	return $?
}

_validate_permission_grant_payload() {
	local payload="$1"
	local request_json="$2"
	jq -e --argjson request "$request_json" '
		.schema == "aidevops-permission-grant/v1"
		and .authority == "worker-permissions"
		and .target == $request.target
		and .request_id == $request.request_id
		and .request_sha256 == $request.request_sha256
		and .worker == $request.worker
		and .capabilities == $request.capabilities
	' <<<"$payload" >/dev/null || return 1
	_permission_grant_time_valid "$payload"
	return $?
}

cmd_verify_permissions() {
	local target_type="${1:-}"
	local target_number="${2:-}"
	local slug="${3:-}"
	local usage="Usage: aidevops approve verify-permissions issue|pr <number> [owner/repo]"
	[[ "$target_type" == "$_PERMISSION_TARGET_ISSUE" || "$target_type" == "pr" ]] || { printf 'MALFORMED_APPROVAL\n'; return 5; }
	_require_number_arg "$target_number" "$target_type" "$usage" >/dev/null 2>&1 || { printf 'MALFORMED_APPROVAL\n'; return 5; }
	slug=$(_resolve_slug_or_fail "$slug" "$usage") || { printf 'API_ERROR\n'; return 6; }
	local request_json request_id grant_body payload
	request_json=$(_fetch_latest_permission_request_json "$target_number" "$slug") || { printf 'NO_REQUEST\n'; return 1; }
	request_id=$(jq -r '.request_id // ""' \
		<<<"$request_json")
	_validate_permission_request_json "$request_json" "$target_type" "$target_number" "$slug" "$request_id" || {
		printf 'MALFORMED_REQUEST\n'
		return 5
	}
	grant_body=$(_fetch_latest_permission_grant_body "$target_number" "$slug" "$request_id") || { printf 'API_ERROR\n'; return 6; }
	[[ -n "$grant_body" ]] || { printf 'NO_APPROVAL\n'; return 1; }
	[[ -f "$APPROVAL_PUB" ]] || { printf 'NO_KEY\n'; return 2; }
	_verify_comment_signature "$grant_body" "$APPROVAL_PUB" || { printf 'MALFORMED_APPROVAL\n'; return 5; }
	payload=$(_extract_fenced_block "$grant_body" 1)
	_validate_permission_grant_payload "$payload" "$request_json" || { printf 'STALE_APPROVAL\n'; return 4; }
	printf 'VERIFIED\n'
	return 0
}
