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

# Capture the final model-owned BLOCKED dossier before the ephemeral output is
# removed. Volatile runner/session/attempt identities and timestamps are
# normalized so equivalent blockers converge across workers and hosts.
terminal_blocker_capture_output() {
	local output_file="$1"
	local normalized="" fingerprint=""
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
candidates = [part for part in parts if marker.search(part)]
candidate = candidates[-1] if candidates else raw
if not marker.search(candidate):
    raise SystemExit(1)

candidate = re.sub(r"\b\d{4}-\d{2}-\d{2}[T ][0-9:.+-]+Z?\b", "<timestamp>", candidate)
candidate = re.sub(r"\b[0-9]{10,16}\b", "<timestamp>", candidate)
candidate = re.sub(
    r"\b(runner|session|attempt(?:_id)?|device|claim(?:_id)?)\s*[=:]\s*\S+",
    lambda match: f"{match.group(1).lower()}=<volatile>",
    candidate,
    flags=re.IGNORECASE,
)
candidate = re.sub(r"\s+", " ", candidate).strip().lower()
if not candidate:
    raise SystemExit(1)
print(candidate[-2000:])
PY
	) || normalized=""
	[[ -n "$normalized" ]] || return 1
	fingerprint=$(_terminal_blocker_hash "$normalized") || return 1
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
	local task_json="" dependency_signature="" target_revision="" canonical=""
	task_json=$(printf '%s' "$issue_json" | jq -c '{title: (.title // ""), body: (.body // "")}' 2>/dev/null) || return 1
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
		| {body: (.body // ""), created_at: .created_at,
		   author_association: (.author_association // "")}
		| select(.author_association | trusted)]
	' 2>/dev/null || return 1
	return 0
}

_terminal_blocker_latest_marker() {
	local comments_json="$1"
	local marker="$2"
	printf '%s' "$comments_json" | jq -c --arg marker "$marker" '
		[.[] | select((.body // "") | contains($marker))]
		| sort_by(.created_at) | last // empty
	' 2>/dev/null
	return $?
}

_terminal_blocker_latest_retry_at() {
	local comments_json="$1"
	printf '%s' "$comments_json" | jq -r --arg marker "$_TBC_RETRY_MARKER" \
		--arg circuit_marker "$_TBC_CIRCUIT_MARKER" '
		[.[] | select((.body // "") as $body
		| ($body | contains($marker)) and (($body | contains($circuit_marker)) | not))
		| .created_at]
		| sort | last // ""
	' 2>/dev/null
	return $?
}

terminal_blocker_release_mode() {
	local comments_json="$1"
	local task_revision="$2"
	local blocker_fingerprint="$3"
	local retry_at="" circuit="" observation="" circuit_at="" observation_at=""
	retry_at=$(_terminal_blocker_latest_retry_at "$comments_json") || retry_at=""
	circuit=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_CIRCUIT_MARKER revision=${task_revision} blocker=${blocker_fingerprint}") || circuit=""
	observation=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_OBSERVATION_MARKER revision=${task_revision} blocker=${blocker_fingerprint}") || observation=""
	circuit_at=$(printf '%s' "$circuit" | jq -r '.created_at // ""' 2>/dev/null) || circuit_at=""
	observation_at=$(printf '%s' "$observation" | jq -r '.created_at // ""' 2>/dev/null) || observation_at=""
	if [[ -n "$circuit_at" && (-z "$retry_at" || "$circuit_at" > "$retry_at") ]]; then
		printf 'open\n'
	elif [[ -n "$observation_at" && (-z "$retry_at" || "$observation_at" > "$retry_at") ]]; then
		printf 'circuit\n'
	else
		printf 'first\n'
	fi
	return 0
}

terminal_blocker_observation_fragment() {
	local task_revision="$1"
	local blocker_fingerprint="$2"
	printf '\n<!-- %s revision=%s blocker=%s -->\n\nTerminal blocker identity: %s. Detailed evidence remains in protected worker telemetry.\n' \
		"$_TBC_OBSERVATION_MARKER" "$task_revision" "$blocker_fingerprint" "$blocker_fingerprint"
	return 0
}

terminal_blocker_circuit_comment() {
	local machine_readable_release="$1"
	local task_revision="$2"
	local blocker_fingerprint="$3"
	printf '<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->\n%s\n<!-- %s revision=%s blocker=%s -->\nTERMINAL_BLOCKER_CIRCUIT active=true observations=2 task_revision=%s blocker=%s\n\nAutomatic redispatch is held because two workers returned the same terminal blocker against unchanged task, dependency, and target revisions. Detailed evidence remains in protected worker telemetry.\n\nA maintainer can retry without deleting history by posting %s. A task, dependency, or target revision change also re-arms dispatch.\n<!-- ops:end -->\n' \
		"$machine_readable_release" "$_TBC_CIRCUIT_MARKER" "$task_revision" \
		"$blocker_fingerprint" "$task_revision" "$blocker_fingerprint" \
		"$_TBC_RETRY_MARKER"
	return 0
}

terminal_blocker_circuit_active() {
	local comments_json="$1"
	local issue_json="$2"
	local repo_slug="$3"
	local issue_number="$4"
	local repo_path="$5"
	local circuit="" circuit_at="" retry_at="" current_revision=""
	circuit=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_CIRCUIT_MARKER revision=") || circuit=""
	[[ -n "$circuit" ]] || return 1
	current_revision=$(terminal_blocker_task_revision "$issue_json" "$repo_slug" "$issue_number" "$repo_path") || return 1
	circuit=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_CIRCUIT_MARKER revision=${current_revision} blocker=") || circuit=""
	[[ -n "$circuit" ]] || return 1
	circuit_at=$(printf '%s' "$circuit" | jq -r '.created_at // ""' 2>/dev/null) || return 1
	retry_at=$(_terminal_blocker_latest_retry_at "$comments_json") || retry_at=""
	if [[ -n "$retry_at" && "$retry_at" > "$circuit_at" ]]; then
		return 1
	fi
	printf 'TERMINAL_BLOCKER_CIRCUIT task_revision=%s\n' "$current_revision"
	return 0
}
