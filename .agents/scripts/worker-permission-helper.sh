#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

readonly PERMISSION_REQUEST_MARKER="<!-- aidevops-permission-request -->"
readonly PERMISSION_REQUEST_SCHEMA="aidevops-permission-request/v1"
readonly PERMISSION_BLOCKER_STATUS="blocked"
readonly PERMISSION_BLOCKER_TRUE="true"
readonly PERMISSION_PERSISTENCE_FAILED_EVENT="permission_request_persistence_failed"

permission_record_blocker() {
	local event="$1"
	local status="$2"
	local reason="$3"
	local blocking="$4"
	local issue_number="$5"
	local repo_slug="$6"
	local session_key="$7"
	local request_id="${8:-}"
	local detail="${9:-}"
	local permission="${10:-}"
	local tool="${11:-}"
	local risk_level="${12:-}"
	local grantable="${13:-}"
	local logger="${SCRIPT_DIR}/worker-blocker-log.mjs"
	[[ -f "$logger" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0
	local blocker_args=(append
		--event "$event"
		--status "$status"
		--reason "$reason"
		--blocking "$blocking"
		--source "worker-permission-helper"
		--issue-number "$issue_number"
		--repo-slug "$repo_slug"
		--session-key "$session_key"
		--request-id "$request_id"
		--permission "$permission"
		--tool "$tool"
		--risk-level "$risk_level"
		--detail "$detail")
	[[ -z "$grantable" ]] || blocker_args+=(--grantable "$grantable")
	node "$logger" "${blocker_args[@]}" >/dev/null 2>&1 || true
	return 0
}

permission_sha256() {
	local source_file="$1"
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$source_file" | awk '{print $1}'
	else
		sha256sum "$source_file" | awk '{print $1}'
	fi
	return 0
}

permission_sha256_text() {
	local value="$1"
	local source_file
	source_file=$(mktemp)
	printf '%s' "$value" >"$source_file"
	permission_sha256 "$source_file"
	rm -f "$source_file"
	return 0
}

permission_validate_capture() {
	local capture_file="$1"
	local issue_number="$2"
	local repo_slug="$3"
	jq -e --arg issue "$issue_number" --arg repo "$repo_slug" '
		.schema == "aidevops-permission-capture/v1"
		and .issue == $issue
		and (.repo | ascii_downcase) == ($repo | ascii_downcase)
		and (.requests | type == "array" and length > 0 and length <= 20)
		and all(.requests[];
			(.permission | type == "string" and length > 0 and length <= 100)
			and (.patterns | type == "array" and length <= 20)
			and all(.patterns[]; type == "string" and length <= 500)
			and (.risk.level as $level | ["low", "medium", "high", "critical"] | index($level) != null)
			and (.risk.grantable | type == "boolean")
		)
		and all(.requests[];
			all((.patterns[]?), .intent;
				(test("^/(Users|home)/[^/]+/") | not)
				and (test("(?i)(api[_-]?key|token|secret|password|authorization)[[:space:]]*[:=][[:space:]]*(?!\\[REDACTED\\])[^[:space:],;]+") | not)
			)
		)
	' "$capture_file" >/dev/null
	return $?
}

# Summarize validated requests without exposing patterns, intent, or raw tool
# metadata. Counts retain multiplicity while scalar fields stay schema-safe.
permission_blocker_capability_json() {
	local capture_file="$1"
	jq -c '
		def counted:
			map(strings | select(length > 0))
			| sort
			| group_by(.)
			| map(.[0] + if length > 1 then "×\(length)" else "" end)
			| join(",")
			| .[0:100];
		.requests as $requests
		| {
			permission: ([$requests[].permission] | counted),
			tool: ([$requests[].tool // ""] | counted),
			risk_level: (["critical", "high", "medium", "low"]
				| map(. as $level | select(any($requests[]; .risk.level == $level)))
				| .[0]),
			grantable: all($requests[]; .risk.grantable == true)
		}
	' "$capture_file"
	return $?
}

permission_changed_files_json() {
	local work_dir="$1"
	if [[ -z "$work_dir" || ! -d "$work_dir" ]]; then
		printf '[]\n'
		return 0
	fi
	local status_output=""
	if ! status_output=$(git -C "$work_dir" status --short 2>/dev/null); then
		printf '[]\n'
		return 0
	fi
	printf '%s\n' "$status_output" |
		jq -Rsc 'split("\n") | map(select(length >= 4) | .[3:]) | map(select(length > 0)) | .[:20]'
	return 0
}

permission_issue_resume_json() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_json=""
	issue_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" --json labels 2>/dev/null) || {
		printf '{"auto_dispatch":false}\n'
		return 0
	}
	jq -c '{auto_dispatch: ((.labels // []) | map(.name) | index("auto-dispatch") != null)}' <<<"$issue_json"
	return 0
}

permission_build_envelope() {
	local capture_file="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local session_key="$4"
	local work_dir="$5"
	local resume_json="${6:-}"
	[[ -n "$resume_json" ]] || resume_json='{"auto_dispatch":false}'
	local changed_files branch worktree_digest created_at base_file digest request_id
	changed_files=$(permission_changed_files_json "$work_dir")
	branch=$(git -C "$work_dir" branch --show-current 2>/dev/null || true)
	worktree_digest=$(permission_sha256_text "$work_dir")
	created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	base_file=$(mktemp)
	jq -cS \
		--arg schema "$PERMISSION_REQUEST_SCHEMA" \
		--arg issue "$issue_number" \
		--arg repo "$(printf '%s' "$repo_slug" | tr '[:upper:]' '[:lower:]')" \
		--arg session "$session_key" \
		--arg branch "$branch" \
		--arg worktree_digest "$worktree_digest" \
		--arg created "$created_at" \
		--argjson changed "$changed_files" \
		--argjson resume "$resume_json" '
		{
			schema: $schema,
			target: {kind: "issue", repository: $repo, number: ($issue | tonumber)},
			worker: {session: $session, branch: $branch, worktree_sha256: $worktree_digest},
			context: {
				stage: "worker tool execution",
				changed_files: $changed,
				alternatives: "The worker was unable to continue within its current permission boundary.",
				resume_auto_dispatch: $resume.auto_dispatch
			},
			capabilities: [.requests[] | {
				permission, patterns, tool, intent, risk,
				opencode: {request_id: .opencode.request_id, session_id: .opencode.session_id}
			}],
			created_at: $created
		}
	' "$capture_file" >"$base_file"
	digest=$(permission_sha256 "$base_file")
	request_id="perm-${digest:0:16}"
	jq -cS --arg id "$request_id" --arg digest "$digest" \
		'. + {request_id: $id, request_sha256: $digest}' "$base_file"
	rm -f "$base_file"
	return 0
}

permission_request_already_posted() {
	local issue_number="$1"
	local repo_slug="$2"
	local request_id="$3"
	gh api "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" --paginate \
		--jq "[.[] | select((.body // \"\") | contains(\"${PERMISSION_REQUEST_MARKER}\") and contains(\"${request_id}\"))] | length" \
		2>/dev/null | awk '$1 > 0 { found=1 } END { exit(found ? 0 : 1) }'
	return $?
}

permission_render_capabilities() {
	local envelope_file="$1"
	jq -r '.capabilities[] |
		def safe: gsub("<"; "&lt;") | gsub(">"; "&gt;");
		def avoidable_tool_bin_read:
			.permission == "external_directory"
			and .tool == "read"
			and any(.patterns[]?; test("/[.](bun|qlty)/bin/[*][*]?$|/[.]local/bin/[*][*]?$"));
		"- **" + .permission + "** via `" + .tool + "` — "
		+ (if (.patterns | length) == 0 then "(no pattern supplied)" else (.patterns | map(tojson | safe) | join(", ")) end)
		+ "\n  - Reason: " + (if .intent == "" then "No additional model rationale was available." else (.intent | safe) end)
		+ "\n  - Risk: **" + .risk.level + "** — " + (.risk.reason | safe)
		+ (if avoidable_tool_bin_read then "\n  - Recovery: Routine tool discovery should use `command -v TOOL`, `TOOL --version`, or a repository wrapper instead of reading the install directory." else "" end)
		+ (if .risk.grantable then "" else "\n  - **Not grantable:** sensitive scope requires an alternative approach." end)' \
		"$envelope_file"
	return $?
}

permission_post_request() {
	local capture_file="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local session_key="$4"
	local work_dir="$5"
	local envelope_file comment_file request_id capability_text changed_text branch resume_json target worker_session
	envelope_file=$(mktemp)
	comment_file=$(mktemp)
	resume_json=$(permission_issue_resume_json "$issue_number" "$repo_slug")
	permission_build_envelope "$capture_file" "$issue_number" "$repo_slug" "$session_key" "$work_dir" "$resume_json" >"$envelope_file"
	request_id=$(jq -r '.request_id' "$envelope_file")
	if permission_request_already_posted "$issue_number" "$repo_slug" "$request_id"; then
		rm -f "$envelope_file" "$comment_file"
		printf '%s\n' "$request_id"
		return 0
	fi
	if ! capability_text=$(permission_render_capabilities "$envelope_file"); then
		rm -f "$envelope_file" "$comment_file"
		return 1
	fi
	if [[ -z "$capability_text" ]]; then
		rm -f "$envelope_file" "$comment_file"
		return 1
	fi
	changed_text=$(jq -r 'if (.context.changed_files | length) == 0 then "- No uncommitted repository files detected." else (.context.changed_files[] | "- " + tojson) end' "$envelope_file")
	branch=$(jq -r '(.worker.branch // "") | tojson' "$envelope_file")
	target=$(jq -r '.target.repository + "#" + (.target.number | tostring)' "$envelope_file")
	worker_session=$(jq -r '.worker.session // "not available"' "$envelope_file")
	cat >"$comment_file" <<EOF
${PERMISSION_REQUEST_MARKER}
## Maintainer permission required

Background work paused instead of waiting indefinitely for an unavailable interactive permission response.

**Request:** ${request_id}

**Target:** \`${target}\`

**Worker session:** \`${worker_session}\`

**Worker stage:** tool execution

**Branch:** ${branch:-not available}

### Requested capabilities

${capability_text}

### Preserved work context

${changed_text}

The worktree and OpenCode session are preserved for continuation. Paths are home/worktree-normalized, credential-like values are redacted, and raw tool metadata is intentionally omitted.

### Approval

Review the exact scope above, then run:

    sudo aidevops approve permissions issue ${issue_number} ${repo_slug} --request ${request_id}

This signs only the listed capabilities for this issue. It does not approve the issue scope, clear needs-maintainer-review, or authorize merge/release.

~~~json
$(jq . "$envelope_file")
~~~
EOF
	if ! gh_issue_comment "$issue_number" --repo "$repo_slug" --body-file "$comment_file" >/dev/null; then
		rm -f "$envelope_file" "$comment_file"
		return 1
	fi
	rm -f "$envelope_file" "$comment_file"
	printf '%s\n' "$request_id"
	return 0
}

permission_apply_block() {
	local issue_number="$1"
	local repo_slug="$2"
	gh_issue_edit_safe "$issue_number" --repo "$repo_slug" \
		--add-label "needs-maintainer-permissions" \
		--remove-label "status:queued" \
		--remove-label "status:claimed" \
		--remove-label "status:in-progress" \
		--remove-label "status:in-review" >/dev/null
	return $?
}

cmd_request() {
	local capture_file="" issue_number="" repo_slug="" session_key="" work_dir=""
	local request_id="" capability_json="" permission="" tool="" risk_level="" grantable=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--file)
			capture_file="${2:-}"
			shift 2
			;;
		--issue)
			issue_number="${2:-}"
			shift 2
			;;
		--repo)
			repo_slug="${2:-}"
			shift 2
			;;
		--session)
			session_key="${2:-}"
			shift 2
			;;
		--work-dir)
			work_dir="${2:-}"
			shift 2
			;;
		*)
			printf 'Unknown option: %s\n' "$arg" >&2
			return 1
			;;
		esac
	done
	[[ -f "$capture_file" && "$issue_number" =~ ^[0-9]+$ && "$repo_slug" == */* ]] || return 1
	if ! permission_validate_capture "$capture_file" "$issue_number" "$repo_slug"; then
		permission_record_blocker "$PERMISSION_PERSISTENCE_FAILED_EVENT" "$PERMISSION_BLOCKER_STATUS" \
			"capture_validation_failed" "$PERMISSION_BLOCKER_TRUE" "$issue_number" "$repo_slug" "$session_key" "" \
			"Captured permission request failed validation"
		return 1
	fi
	capability_json="$(permission_blocker_capability_json "$capture_file")" || return 1
	permission="$(jq -r '.permission' <<<"$capability_json")"
	tool="$(jq -r '.tool' <<<"$capability_json")"
	risk_level="$(jq -r '.risk_level' <<<"$capability_json")"
	grantable="$(jq -r '.grantable' <<<"$capability_json")"
	if ! request_id=$(permission_post_request "$capture_file" "$issue_number" "$repo_slug" "$session_key" "$work_dir"); then
		permission_record_blocker "$PERMISSION_PERSISTENCE_FAILED_EVENT" "$PERMISSION_BLOCKER_STATUS" \
			"github_request_comment_failed" "$PERMISSION_BLOCKER_TRUE" "$issue_number" "$repo_slug" "$session_key" "" \
			"Maintainer permission request comment could not be persisted"
		return 1
	fi
	if ! permission_apply_block "$issue_number" "$repo_slug"; then
		permission_record_blocker "$PERMISSION_PERSISTENCE_FAILED_EVENT" "$PERMISSION_BLOCKER_STATUS" \
			"github_block_label_failed" "$PERMISSION_BLOCKER_TRUE" "$issue_number" "$repo_slug" "$session_key" "$request_id" \
			"Maintainer permission blocker label could not be persisted"
		return 1
	fi
	if [[ -n "$work_dir" && -d "$work_dir" ]]; then
		local git_dir="" pending_file=""
		if ! git_dir=$(git -C "$work_dir" rev-parse --absolute-git-dir 2>/dev/null); then
			permission_record_blocker "$PERMISSION_PERSISTENCE_FAILED_EVENT" "$PERMISSION_BLOCKER_STATUS" \
				"git_directory_lookup_failed" "$PERMISSION_BLOCKER_TRUE" "$issue_number" "$repo_slug" "$session_key" "$request_id" \
				"Permission pending marker location could not be resolved"
			return 1
		fi
		pending_file="${git_dir}/aidevops-permission-pending"
		if ! jq -cn --arg request "$request_id" --arg issue "$issue_number" --arg session "$session_key" \
			'{request_id: $request, issue: ($issue | tonumber), session: $session}' >"$pending_file"; then
			permission_record_blocker "$PERMISSION_PERSISTENCE_FAILED_EVENT" "$PERMISSION_BLOCKER_STATUS" \
				"pending_marker_write_failed" "$PERMISSION_BLOCKER_TRUE" "$issue_number" "$repo_slug" "$session_key" "$request_id" \
				"Permission pending marker could not be persisted"
			return 1
		fi
	fi
	permission_record_blocker "permission_awaiting_approval" "$PERMISSION_BLOCKER_STATUS" \
		"needs_maintainer_permissions" "$PERMISSION_BLOCKER_TRUE" "$issue_number" "$repo_slug" "$session_key" "$request_id" \
		"Worker paused until the exact scoped permission request is approved" \
		"$permission" "$tool" "$risk_level" "$grantable"
	return 0
}

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true
	case "$command" in
	request) cmd_request "$@" ;;
	*)
		printf 'Usage: worker-permission-helper.sh request --file FILE --issue N --repo OWNER/REPO --session KEY --work-dir PATH\n' >&2
		return 1
		;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
