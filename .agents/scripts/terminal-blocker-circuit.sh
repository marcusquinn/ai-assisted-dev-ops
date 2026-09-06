#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Durable, cross-runner suppression for unchanged terminal worker blockers.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_TERMINAL_BLOCKER_CIRCUIT_LOADED:-}" ]] && return 0
_TERMINAL_BLOCKER_CIRCUIT_LOADED=1

_TBC_OBSERVATION_MARKER='aidevops:terminal-blocker-observation'
_TBC_CIRCUIT_MARKER='aidevops:terminal-blocker-circuit'
_TBC_RETRY_MARKER='terminal-blocker-circuit:retry'
_TBC_MISSING_SCOPE='missing_files_scope'
_TBC_UNKNOWN='unknown'
_TBC_AUTHORITATIVE_ASSOCIATIONS='["OWNER","MEMBER"]'

# IDs break same-second ties only when both are positive, exact JSON integers.
# Legacy/malformed IDs never let a tied retry clear evidence. For selection,
# unknown marker IDs sort last (conservative hold), unknown retry IDs first.
# shellcheck disable=SC2016 # Shared jq definitions, not shell expansions.
_TBC_ORDER_JQ='
def comment_id:
  .id | if type == "number" then
    if . > 0 and . <= 9007199254740991 and floor == . then . else null end
  else null end;
def valid_time: try (.created_at | fromdateiso8601 | . > 0) catch false;
def retry_after($event):
  . as $retry | ($retry.created_at // "") as $at
  | ($event.created_at // "") as $before
  | ($retry | valid_time) and ($event | valid_time) and
    ($at > $before or ($at == $before and
      ($retry | comment_id) != null and ($event | comment_id) != null and
      ($retry | comment_id) > ($event | comment_id)));
'

_terminal_blocker_retry_after() {
	local retry="$1"
	local event="$2"
	[[ -n "$retry" && -n "$event" ]] || return 1
	printf '%s' "$retry" | jq -e --argjson event "$event" \
		"${_TBC_ORDER_JQ}"'retry_after($event)' >/dev/null 2>&1
	return $?
}

_terminal_blocker_hash() {
	local value="$1"
	local digest=""
	if command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | shasum -a 256 2>/dev/null | cut -c1-24) || digest=""
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | sha256sum 2>/dev/null | cut -c1-24) || digest=""
	fi
	[[ "$digest" =~ ^[a-f0-9]{24}$ ]] || return 1
	printf '%s\n' "$digest"
	return 0
}

# Versioned, allowlisted classes are the only public identities. Never hash prose
# into a durable hold. Models may interpret a dossier with an exact standalone
# TERMINAL_BLOCKER_REASON=<class> line; unclassified evidence remains retryable.
_terminal_blocker_reason() {
	local fingerprint="$1"
	local reason=""
	for reason in missing_files_scope files_scope_excluded target_code_blocker permission_required unknown; do
		if [[ "$fingerprint" == "$(_terminal_blocker_hash "v2:${reason}")" ]]; then
			printf '%s\n' "$reason"
			return 0
		fi
	done
	printf 'unknown\n'
	return 0
}

# Capture only final assistant text, not tool output. A missing canonical scope
# can also be established from the current brief, without interpreting prose.
terminal_blocker_capture_output() {
	local output_file="$1"
	local normalized="" fingerprint="" issue_json=""
	AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=""
	[[ -f "$output_file" ]] || return 1
	normalized=$(
		python3 - "$output_file" <<'PY'
import json
import re
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text(errors="ignore")
parts = []
text_field = "text"
for raw_line in raw.splitlines():
    line = raw_line.strip()
    if not line.startswith("{"):
        continue
    try:
        event = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue
    if not isinstance(event, dict) or event.get("type") != text_field:
        continue
    part = event.get("part") if isinstance(event.get("part"), dict) else {}
    text = event.get(text_field) or part.get(text_field) or ""
    if text:
        parts.append(text)

marker = re.compile(r"(^|\n)\s*BLOCKED(?:\s*:|\s*$)", re.IGNORECASE)
candidate = parts[-1] if parts else (raw if not raw.lstrip().startswith('{') else '')
if not marker.search(candidate):
    raise SystemExit(1)

reasons = re.findall(r"^TERMINAL_BLOCKER_REASON=(.*)$", candidate, re.M)
allowed = {'missing_files_scope', 'files_scope_excluded', 'target_code_blocker', 'permission_required'}
print(reasons[0] if len(reasons) == 1 and reasons[0] in allowed else 'unknown')
PY
	) || normalized=""
	[[ -n "$normalized" ]] || return 1
	# Do not infer a missing heading from words such as "Files Scope excludes".
	# Verify the structural condition independently against the issue itself.
	if [[ "$normalized" != "permission_required" && "${WORKER_ISSUE_NUMBER:-}" =~ ^[0-9]+$ &&
		"${DISPATCH_REPO_SLUG:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		issue_json=$(gh api "repos/${DISPATCH_REPO_SLUG}/issues/${WORKER_ISSUE_NUMBER}" 2>/dev/null) || issue_json=""
		if printf '%s' "$issue_json" | jq -e '.body | type == "string"' >/dev/null 2>&1 &&
			! printf '%s' "$issue_json" | jq -e '.body | test("(?m)^#{2,3} Files Scope[ \\t]*\\r?$")' >/dev/null 2>&1; then
			normalized="$_TBC_MISSING_SCOPE"
		elif [[ "$normalized" == "$_TBC_MISSING_SCOPE" ]]; then
			normalized="$_TBC_UNKNOWN"
		fi
	elif [[ "$normalized" == "$_TBC_MISSING_SCOPE" ]]; then
		normalized="$_TBC_UNKNOWN"
	fi
	fingerprint=$(_terminal_blocker_hash "v2:${normalized}") || return 1
	AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT="$fingerprint"
	return 0
}

_terminal_blocker_dependency_signature() {
	local repo_slug="$1"
	local issue_number="$2"
	local owner="${repo_slug%%/*}"
	local repo_name="${repo_slug#*/}"
	local response="" signature=""
	[[ "$repo_slug" == */* && "$issue_number" =~ ^[0-9]+$ ]] || return 1
	# shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub.
	response=$(gh api graphql \
		-f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){blockedBy(first:50){nodes{number state}pageInfo{hasNextPage}}}}}' \
		-F owner="$owner" -F name="$repo_name" -F number="$issue_number" 2>/dev/null) || return 1
	signature=$(printf '%s' "$response" | jq -c '
		.data.repository.issue.blockedBy as $blocked
		| {truncated: ($blocked.pageInfo.hasNextPage // true),
		   nodes: ([($blocked.nodes // [])[] | {number, state}] | sort_by(.number))}
	' 2>/dev/null) || return 1
	[[ -n "$signature" && "$signature" != "null" ]] || return 1
	printf '%s\n' "$signature"
	return 0
}

_terminal_blocker_target_revision() {
	local repo_path="$1"
	local revision="" remote_head=""
	[[ -d "$repo_path" ]] || return 1
	remote_head=$(git -C "$repo_path" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) || remote_head=""
	if [[ -n "$remote_head" ]]; then
		revision=$(git -C "$repo_path" rev-parse "${remote_head}^{commit}" 2>/dev/null) || revision=""
	fi
	if [[ -z "$revision" ]]; then
		revision=$(git -C "$repo_path" rev-parse 'origin/main^{commit}' 2>/dev/null) || revision=""
	fi
	if [[ -z "$revision" ]]; then
		revision=$(git -C "$repo_path" rev-parse 'origin/master^{commit}' 2>/dev/null) || revision=""
	fi
	[[ "$revision" =~ ^[a-f0-9]{40,64}$ ]] || return 1
	printf '%s\n' "$revision"
	return 0
}

terminal_blocker_task_revision() {
	local issue_json="$1"
	local repo_slug="$2"
	local issue_number="$3"
	local repo_path="$4"
	local reason="${5:-}"
	local task_json="" dependency_signature="" target_revision="" canonical=""
	[[ -n "$reason" ]] || reason=$(_terminal_blocker_reason "${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT:-}")
	# A brief edit, unrelated merge or GraphQL outage cannot satisfy a permission
	# prerequisite. Explicit retry only schedules a new check; it grants nothing.
	if [[ "$reason" == "permission_required" ]]; then
		[[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue_number" =~ ^[0-9]+$ ]] || return 1
		_terminal_blocker_hash "v2:${reason}:${repo_slug}:${issue_number}"
		return $?
	fi
	task_json=$(printf '%s' "$issue_json" | jq -c '{title: (.title // ""), body: (.body // "")}' 2>/dev/null) || return 1
	if [[ "$reason" == "$_TBC_MISSING_SCOPE" || "$reason" == "files_scope_excluded" ]]; then
		_terminal_blocker_hash "v2:${reason}:${task_json}"
		return $?
	fi
	dependency_signature=$(_terminal_blocker_dependency_signature "$repo_slug" "$issue_number") || return 1
	target_revision=$(_terminal_blocker_target_revision "$repo_path") || return 1
	canonical=$(jq -nc --argjson task "$task_json" --argjson dependencies "$dependency_signature" \
		--arg target "$target_revision" '{task: $task, dependencies: $dependencies, target_revision: $target}') || return 1
	_terminal_blocker_hash "$canonical"
	return $?
}

terminal_blocker_fetch_trusted_comments() {
	local issue_number="$1"
	local repo_slug="$2"
	local raw=""
	raw=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	printf '%s' "$raw" | jq -c '
		def trusted: . == "OWNER" or . == "MEMBER" or . == "COLLABORATOR";
		[(if type == "array" and ((.[0]? | type) == "array") then .[] else . end)[]
		| {id: .id, author: (.user.login // ""), body: (.body // ""), created_at: .created_at,
		   author_association: (.author_association // "")}
		| select(.author_association | trusted)]
	' 2>/dev/null || return 1
	return 0
}

_terminal_blocker_latest_marker() {
	local comments_json="$1"
	local marker="$2"
	# aidevops:trust-boundary — a deterministic marker is not a signature.
	# The same authoritative actors must own both opening and clearing a hold.
	printf '%s' "$comments_json" | jq -c --arg marker "$marker" \
		--argjson authoritative "$_TBC_AUTHORITATIVE_ASSOCIATIONS" "${_TBC_ORDER_JQ}"'
		[.[] | select(.author_association as $a | $authoritative | index($a) != null)
		| select((.body // "") | contains($marker))]
		| sort_by(.created_at, (comment_id // 9007199254740992), .body) | last // empty
	' 2>/dev/null
	return $?
}

_terminal_blocker_latest_retry_comment() {
	local comments_json="$1"
	# aidevops:trust-boundary — retry affects scheduling, not source authority;
	# ambiguous collaborators and quoted recovery prose cannot authorize it.
	printf '%s' "$comments_json" | jq -c --arg marker "$_TBC_RETRY_MARKER" \
		--argjson authoritative "$_TBC_AUTHORITATIVE_ASSOCIATIONS" \
		--arg circuit_marker "$_TBC_CIRCUIT_MARKER" "${_TBC_ORDER_JQ}"'
		[.[] | select(.author_association as $a | $authoritative | index($a) != null)
		| select(valid_time)
		| select((.body // "") as $body
		| ($body | test("(?m)^" + $marker + "[ \\t]*\\r?$")) and (($body | contains($circuit_marker)) | not))
		]
		| sort_by(.created_at, (comment_id // 0), .body) | last // empty
	' 2>/dev/null
	return $?
}

# Compatibility for timestamp-only callers; scheduling uses the full comment.
_terminal_blocker_latest_retry_at() {
	local comments_json="$1"
	local retry=""
	retry=$(_terminal_blocker_latest_retry_comment "$comments_json") || return 1
	printf '%s' "${retry:-null}" | jq -r '.created_at // ""'
	return $?
}

terminal_blocker_release_mode() {
	local comments_json="$1"
	local task_revision="$2"
	local blocker_fingerprint="$3"
	local retry="" circuit="" observation="" circuit_at="" observation_at=""
	retry=$(_terminal_blocker_latest_retry_comment "$comments_json") || retry=""
	circuit=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_CIRCUIT_MARKER revision=${task_revision} blocker=${blocker_fingerprint}") || circuit=""
	observation=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_OBSERVATION_MARKER revision=${task_revision} blocker=${blocker_fingerprint}") || observation=""
	circuit_at=$(printf '%s' "$circuit" | jq -r '.created_at // ""' 2>/dev/null) || circuit_at=""
	observation_at=$(printf '%s' "$observation" | jq -r '.created_at // ""' 2>/dev/null) || observation_at=""
	# Unknown dossiers can have one safe observation, never a durable circuit.
	# Preserve each new CLAIM_RELEASED audit event, but omit repeated explanations.
	if [[ "$(_terminal_blocker_reason "$blocker_fingerprint")" == "$_TBC_UNKNOWN" ]]; then
		if [[ -n "$observation_at" ]] && ! _terminal_blocker_retry_after "$retry" "$observation"; then
			printf 'normal\n'
		else
			printf 'first\n'
		fi
		return 0
	fi
	if [[ -n "$circuit_at" ]] && ! _terminal_blocker_retry_after "$retry" "$circuit"; then
		printf 'open\n'
	elif [[ -n "$observation_at" ]] && ! _terminal_blocker_retry_after "$retry" "$observation"; then
		printf 'circuit\n'
	else
		printf 'first\n'
	fi
	return 0
}

terminal_blocker_observation_fragment() {
	local task_revision="$1"
	local blocker_fingerprint="$2"
	printf '\n<!-- %s revision=%s blocker=%s -->\n\n' \
		"$_TBC_OBSERVATION_MARKER" "$task_revision" "$blocker_fingerprint"
	_terminal_blocker_recovery "$blocker_fingerprint"
	return 0
}

_terminal_blocker_recovery() {
	local fingerprint="$1"
	local reason="" owner="" action="" attempt="" issue="${WORKER_ISSUE_NUMBER:-unknown}"
	reason=$(_terminal_blocker_reason "$fingerprint")
	case "$reason" in
	missing_files_scope)
		owner="brief-author"
		action='Add a canonical ### Files Scope (or legacy ## Files Scope) section listing the permitted paths in the issue body.'
		;;
	files_scope_excluded)
		owner="brief-author"
		action='The AI brief owner must review the protected integration dossier, check concurrent ownership and correct the permitted paths before resuming the existing checkpoint. Preserve explicit hard boundaries and security guarantees; do not retry an unchanged brief.'
		;;
	target_code_blocker)
		owner="target-maintainer"
		action='Review the protected blocker dossier and correct the target code or task dependencies before retrying.'
		;;
	permission_required)
		owner="permission-maintainer"
		action='Resolve the evidenced permission prerequisite through the human-owned approval flow, then post the explicit retry directive. Retry is scheduling consent only: the original permission guard must independently verify the exact context. Do not regenerate requests or bypass the guard.'
		;;
	*)
		owner="worker-triage"
		action='Interpret the protected dossier and record a known blocker class or repair the brief. No global dispatch hold is imposed.'
		;;
	esac
	[[ "$issue" =~ ^[0-9]+$ ]] || issue="$_TBC_UNKNOWN"
	# Correlate attempts without publishing runner names or arbitrary env text.
	attempt=$(_terminal_blocker_hash "${AIDEVOPS_ATTEMPT_ID:-${WORKER_SESSION_KEY:-unknown}}") || attempt="$_TBC_UNKNOWN"
	printf 'Terminal blocker: reason=%s owner=%s task=%s attempt=%s.\nNext action: %s\nRaw evidence remains in protected worker telemetry.\n' \
		"$reason" "$owner" "$issue" "$attempt" "$action"
	return 0
}

terminal_blocker_circuit_comment() {
	local machine_readable_release="$1"
	local task_revision="$2"
	local blocker_fingerprint="$3"
	[[ "$(_terminal_blocker_reason "$blocker_fingerprint")" != "$_TBC_UNKNOWN" ]] || return 1
	printf '<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->\n%s\n<!-- %s revision=%s blocker=%s -->\nTERMINAL_BLOCKER_CIRCUIT active=true observations=2 task_revision=%s blocker=%s\n\nAutomatic redispatch is held for the repeated known blocker. See the preceding recovery observation.\n\nAn OWNER/MEMBER can retry without deleting history by posting %s as a standalone line. Relevant revisions re-arm code/brief blockers, but never permission blockers. Retry schedules verification only and grants no access.\n<!-- ops:end -->\n' \
		"$machine_readable_release" "$_TBC_CIRCUIT_MARKER" "$task_revision" \
		"$blocker_fingerprint" "$task_revision" "$blocker_fingerprint" \
		"$_TBC_RETRY_MARKER"
	return 0
}

# Unknown/legacy BLOCKED results remain retryable, but not on every pulse. Use
# shared GitHub evidence, independent of local counters, model prose, target
# revisions and comment-bloat mode. Expiry or an explicit trusted retry re-arms
# dispatch; no labels or comments are written by this gate.
terminal_blocker_backoff_active() {
	local comments_json="$1"
	local now_epoch="${TERMINAL_BLOCKER_NOW_EPOCH:-}"
	local evidence="" count=0 last_epoch=0 delay=900 steps=0
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=$(date -u '+%s')
	# aidevops:trust-boundary — bare COLLABORATOR is not proof of write access.
	# Accept only OWNER/MEMBER releases whose runner matches the API author.
	# A retry must be a standalone directive, not quoted recovery instructions.
	evidence=$(printf '%s' "$comments_json" | jq -r --argjson now "$now_epoch" \
		--argjson associations "$_TBC_AUTHORITATIVE_ASSOCIATIONS" "${_TBC_ORDER_JQ}"'
		def authoritative: .author_association as $a | $associations | index($a) != null;
		def epoch: try (.created_at | fromdateiso8601) catch 0;
		[.[] | select(authoritative) | select(epoch > 0 and epoch <= $now)] as $trusted
		| ([$trusted[] | select((.body // "") | test("(?m)^terminal-blocker-circuit:retry[ \\t]*\\r?$"))
			| select((.body // "") | contains("aidevops:terminal-blocker-circuit") | not)]
			| sort_by(.created_at, (comment_id // 0), .body) | last) as $retry
		| [$trusted[] | . as $event | select(($retry | retry_after($event)) | not)
			| . as $comment
			| ((.body // "") | try capture("(?m)^CLAIM_RELEASED reason=blocked runner=(?<runner>[A-Za-z0-9-]+) ") catch null) as $release
			| select($release != null and $release.runner == ($comment.author // $comment.user.login // ""))
			| epoch] | [length, (max // 0)] | @tsv
	' 2>/dev/null) || return 1
	IFS=$'\t' read -r count last_epoch <<<"$evidence"
	[[ "$count" =~ ^[0-9]+$ && "$last_epoch" =~ ^[0-9]+$ && "$count" -ge 2 ]] || return 1
	# Two failures: 15 minutes; each further failure doubles the delay, capped
	# at 24 hours. Cap before arithmetic so even very long histories stay safe.
	steps=$((count - 2))
	[[ "$steps" -le 7 ]] || steps=7
	while [[ "$steps" -gt 0 ]]; do
		delay=$((delay * 2))
		steps=$((steps - 1))
	done
	[[ "$delay" -le 86400 ]] || delay=86400
	[[ "$((now_epoch - last_epoch))" -lt "$delay" ]] || return 1
	printf 'TERMINAL_BLOCKER_BACKOFF failures=%s retry_after=%s\n' "$count" "$((last_epoch + delay))"
	return 0
}

terminal_blocker_circuit_active() {
	local comments_json="$1"
	local issue_json="$2"
	local repo_slug="$3"
	local issue_number="$4"
	local repo_path="$5"
	local circuit="" retry="" current_revision="" fingerprint="" reason=""
	if terminal_blocker_backoff_active "$comments_json"; then
		return 0
	fi
	circuit=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_CIRCUIT_MARKER revision=") || circuit=""
	[[ -n "$circuit" ]] || return 1
	fingerprint=$(printf '%s' "$circuit" | jq -r '.body | capture("<!-- aidevops:terminal-blocker-circuit revision=[a-f0-9]{24} blocker=(?<id>[a-f0-9]{24}) -->").id' 2>/dev/null) || return 1
	reason=$(_terminal_blocker_reason "$fingerprint")
	[[ "$reason" != "$_TBC_UNKNOWN" ]] || return 1
	current_revision=$(terminal_blocker_task_revision "$issue_json" "$repo_slug" "$issue_number" "$repo_path" "$reason") || return 1
	circuit=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_CIRCUIT_MARKER revision=${current_revision} blocker=${fingerprint}") || circuit=""
	[[ -n "$circuit" ]] || return 1
	retry=$(_terminal_blocker_latest_retry_comment "$comments_json") || retry=""
	if _terminal_blocker_retry_after "$retry" "$circuit"; then
		return 1
	fi
	printf 'TERMINAL_BLOCKER_CIRCUIT task_revision=%s\n' "$current_revision"
	return 0
}
