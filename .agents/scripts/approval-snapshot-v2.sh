#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# approval-snapshot-v2.sh — deterministic content/head snapshots for approvals.

[[ -n "${_APPROVAL_SNAPSHOT_V2_LOADED:-}" ]] && return 0
_APPROVAL_SNAPSHOT_V2_LOADED=1
APPROVAL_TARGET_ISSUE="issue"

_approval_snapshot_v2_create_temp_dir() {
	local root="${AIDEVOPS_TEMP_DIR:-${HOME:?}/.aidevops/.agent-workspace/tmp}"
	local temp_dir=""
	(umask 077 && mkdir -p "$root") || return 1
	chmod 700 "$root" 2>/dev/null || return 1
	temp_dir=$(mktemp -d "$root/approval-snapshot-v2.XXXXXX") || return 1
	chmod 700 "$temp_dir" 2>/dev/null || {
		rm -rf "$temp_dir"
		return 1
	}
	printf '%s\n' "$temp_dir"
	return 0
}

_approval_snapshot_v2_write_json_file() {
	local path="$1"
	local json="$2"
	(umask 077 && printf '%s' "$json" >"$path") || return 1
	chmod 600 "$path" 2>/dev/null || return 1
	jq -e . "$path" >/dev/null 2>&1 || return 1
	return 0
}

_approval_snapshot_v2_fetch_pages() {
	local endpoint="$1"
	local pages=""

	pages=$(gh api "$endpoint" --paginate --slurp 2>/dev/null) || return 1
	printf '%s' "$pages" | jq -e 'type == "array" and all(.[]; type == "array")' >/dev/null 2>&1 || return 1
	printf '%s\n' "$pages"
	return 0
}

_approval_snapshot_v2_comments_json() {
	local pages_json="$1"
	local excluded_comment_id="${2:-}"
	local source_name="${3:-conversation}"
	local empty_string=""

	# #aidevops:trust-boundary — exclude the exact approval comment whose
	# signature is being verified plus the strict trusted-association lifecycle
	# audit written after verification. Marker text is attacker-controlled:
	# excluding arbitrary marker comments would let an external contributor hide
	# later drift by copying the marker into an unsigned comment.
	jq -cS --arg excluded "$excluded_comment_id" --arg source "$source_name" --arg empty "$empty_string" '
		[.[][]?
		| select((.id | tostring) != $excluded)
		| select((.user.type // $empty) != "Bot")
		| select((
			((.author_association // $empty) == "OWNER" or (.author_association // $empty) == "MEMBER" or (.author_association // $empty) == "COLLABORATOR")
			and ((.body // $empty) | startswith("<!-- aidevops-signed-approval -->\n<!-- stale-recovery-tick:0 (reset: auto-approved by maintainer — "))
			and ((.body // $empty) | contains(") -->\nAuto-approved: "))
			and ((.body // $empty) | contains(". Stale recovery tick reset."))
		) | not)
		| select((
			((.author_association // $empty) == "OWNER" or (.author_association // $empty) == "MEMBER" or (.author_association // $empty) == "COLLABORATOR")
			and ((.body // $empty) | test("^<!-- ops:start -->\\n> Interactive session claimed by @[^\\n]+ on [^\\n]+\\.\\n> Pulse dispatch blocked via `status:in-review` \\+ self-assignment\\.\\n<!-- ops:end -->\\n<!-- aidevops:sig -->\\n---\\n[^\\n]+\\n?$"))
		) | not)
		| {
			source: $source,
			id: .id,
			node_id: (.node_id // ""),
			author: {
				id: (.user.id // null),
				node_id: (.user.node_id // $empty),
				login: (.user.login // $empty),
				type: (.user.type // $empty)
			},
			author_association: (.author_association // $empty),
			created_at: (.created_at // $empty),
			updated_at: (.updated_at // .created_at // $empty),
			body: (.body // $empty),
			path: (.path // null),
			line: (.line // null),
			side: (.side // null),
			commit_id: (.commit_id // null),
			original_commit_id: (.original_commit_id // null)
		}
		] | sort_by(.source, .id)
	' <<<"$pages_json"
	return $?
}

_approval_snapshot_v2_linked_references_json() {
	local pages_json="$1"
	local issued_at_cutoff="${2:-}"
	local source_timestamp_profile="${3:-stable}"
	local empty_string=""
	local timestamp_pattern='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
	[[ "$source_timestamp_profile" == "stable" || "$source_timestamp_profile" == "legacy" ]] || return 1

	# GitHub timeline cross-reference events are the authoritative read-only
	# projection of issue/PR links. Keep external text and URLs as opaque bytes;
	# this helper never follows or executes them.
	# #aidevops:trust-boundary — approval authority covers references visible at
	# signing time. A later reference cannot extend that signed authority and must
	# not revoke it when GitHub exposes the timeline event asynchronously.
	# Linked-source updated_at is intentionally excluded: any source comment
	# mutates it, so reciprocal issue/PR approval comments would make the two
	# signatures mutually stale. Source identity and scope-bearing content remain
	# bound below.
	jq -cS --arg empty "$empty_string" --arg cutoff "$issued_at_cutoff" --arg timestamp_pattern "$timestamp_pattern" \
		--arg source_timestamp_profile "$source_timestamp_profile" '
		def is_linked_reference:
			(.event // $empty) == "cross-referenced"
			or (.event // $empty) == "connected"
			or (.event // $empty) == "disconnected"
			or (.event // $empty) == "referenced";
		def is_valid_timestamp:
			. as $timestamp
			| ($timestamp | type) == "string"
			and ($timestamp | test($timestamp_pattern))
			and ((try ($timestamp | fromdateiso8601 | todateiso8601) catch $empty) == $timestamp);
		if $cutoff != $empty and (($cutoff | is_valid_timestamp) | not) then
			error("approval cutoff has no authoritative issued_at")
		elif $cutoff != $empty and any(.[][]?; is_linked_reference and (((.created_at // $empty) | is_valid_timestamp) | not)) then
			error("linked reference has no authoritative created_at")
		else
		[.[][]?
		| select(is_linked_reference)
		| select($cutoff == $empty or .created_at <= $cutoff)
		| {
			event: (.event // $empty),
			id: (.id // null),
			node_id: (.node_id // $empty),
			created_at: (.created_at // $empty),
			updated_at: (.updated_at // .created_at // $empty),
			actor: {
				id: (.actor.id // null),
				node_id: (.actor.node_id // $empty),
				login: (.actor.login // $empty),
				type: (.actor.type // $empty)
			},
			commit_id: (.commit_id // $empty),
			commit_url: (.commit_url // $empty),
			source: (if (.source.issue // null) == null then null else ({
				kind: (if (.source.issue.pull_request // null) == null then "issue" else "pr" end),
				repository: ((.source.issue.repository.full_name // $empty) | ascii_downcase),
				number: (.source.issue.number // null),
				id: (.source.issue.id // null),
				node_id: (.source.issue.node_id // $empty),
				title: (.source.issue.title // $empty),
				body: (.source.issue.body // $empty),
				state: (.source.issue.state // $empty),
				author: {
					id: (.source.issue.user.id // null),
					node_id: (.source.issue.user.node_id // $empty),
					login: (.source.issue.user.login // $empty),
					type: (.source.issue.user.type // $empty)
				}
			} + (if $source_timestamp_profile == "legacy" then {
				updated_at: (.source.issue.updated_at // $empty)
			} else {} end)) end)
		}
		] | sort_by(.created_at, .event, .id)
		end
	' <<<"$pages_json"
	return $?
}

_approval_snapshot_v2_reviews_json() {
	local pages_json="$1"
	local empty_string=""

	jq -cS --arg empty "$empty_string" '
		[.[][]?
		| select((.user.type // $empty) != "Bot")
		| {
			id: .id,
			node_id: (.node_id // ""),
			author: {
				id: (.user.id // null),
				node_id: (.user.node_id // $empty),
				login: (.user.login // $empty),
				type: (.user.type // $empty)
			},
			author_association: (.author_association // $empty),
			state: (.state // $empty),
			commit_id: (.commit_id // $empty),
			submitted_at: (.submitted_at // $empty),
			body: (.body // $empty)
		}
		] | sort_by(.id)
	' <<<"$pages_json"
	return $?
}

approval_snapshot_v2_build() (
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local excluded_comment_id="${4:-}"
	local issued_at_cutoff="${5:-}"
	local source_timestamp_profile="${6:-stable}"
	local issue_json="" comments_pages="" comments_json="" timeline_pages="" linked_references_json="" normalized_slug=""
	local empty_string=""
	local temp_dir=""

	[[ "$target_type" == "$APPROVAL_TARGET_ISSUE" || "$target_type" == "pr" ]] || return 1
	[[ "$target_number" =~ ^[0-9]+$ && "$slug" == */* ]] || return 1
	normalized_slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')

	issue_json=$(gh api "repos/${slug}/issues/${target_number}" 2>/dev/null) || return 1
	printf '%s' "$issue_json" | jq -e 'type == "object" and (.id != null) and (.node_id != null)' >/dev/null 2>&1 || return 1
	if [[ "$target_type" == "pr" ]]; then
		printf '%s' "$issue_json" | jq -e 'has("pull_request")' >/dev/null 2>&1 || return 1
	else
		printf '%s' "$issue_json" | jq -e 'has("pull_request") | not' >/dev/null 2>&1 || return 1
	fi

	comments_pages=$(_approval_snapshot_v2_fetch_pages "repos/${slug}/issues/${target_number}/comments?per_page=100") || return 1
	comments_json=$(_approval_snapshot_v2_comments_json "$comments_pages" "$excluded_comment_id" "conversation") || return 1
	timeline_pages=$(_approval_snapshot_v2_fetch_pages "repos/${slug}/issues/${target_number}/timeline?per_page=100") || return 1
	linked_references_json=$(_approval_snapshot_v2_linked_references_json "$timeline_pages" "$issued_at_cutoff" "$source_timestamp_profile") || return 1
	temp_dir=$(_approval_snapshot_v2_create_temp_dir) || return 1
	trap 'rm -rf "$temp_dir"' EXIT
	_approval_snapshot_v2_write_json_file "$temp_dir/issue.json" "$issue_json" || return 1
	_approval_snapshot_v2_write_json_file "$temp_dir/comments.json" "$comments_json" || return 1
	_approval_snapshot_v2_write_json_file "$temp_dir/linked-references.json" "$linked_references_json" || return 1

	if [[ "$target_type" == "$APPROVAL_TARGET_ISSUE" ]]; then
		jq -cS -n --arg repo "$normalized_slug" --arg empty "$empty_string" --arg issue_kind "$APPROVAL_TARGET_ISSUE" --argjson number "$target_number" \
			--slurpfile issue_input "$temp_dir/issue.json" --slurpfile comments_input "$temp_dir/comments.json" \
			--slurpfile linked_references_input "$temp_dir/linked-references.json" '
			($issue_input[0]) as $issue |
			{
				schema: "aidevops-approval-snapshot/v2",
				target: {kind: $issue_kind, repository: $repo, number: $number, id: $issue.id, node_id: $issue.node_id},
				author: {
					id: ($issue.user.id // null), node_id: ($issue.user.node_id // $empty),
					login: ($issue.user.login // $empty), type: ($issue.user.type // $empty),
					association: ($issue.author_association // $empty)
				},
				created_at: ($issue.created_at // $empty),
				title: ($issue.title // $empty),
				body: ($issue.body // $empty),
				comments: $comments_input[0],
				linked_references: $linked_references_input[0]
			}
		'
		return $?
	fi

	local pr_json="" review_comment_pages="" review_comments_json="" review_pages="" reviews_json=""
	pr_json=$(gh api "repos/${slug}/pulls/${target_number}" 2>/dev/null) || return 1
	printf '%s' "$pr_json" | jq -e --arg empty "$empty_string" 'type == "object" and (.id != null) and (.node_id != null) and ((.head.sha // $empty) != $empty) and ((.base.ref // $empty) != $empty)' >/dev/null 2>&1 || return 1
	review_comment_pages=$(_approval_snapshot_v2_fetch_pages "repos/${slug}/pulls/${target_number}/comments?per_page=100") || return 1
	review_comments_json=$(_approval_snapshot_v2_comments_json "$review_comment_pages" "" "review") || return 1
	review_pages=$(_approval_snapshot_v2_fetch_pages "repos/${slug}/pulls/${target_number}/reviews?per_page=100") || return 1
	reviews_json=$(_approval_snapshot_v2_reviews_json "$review_pages") || return 1
	_approval_snapshot_v2_write_json_file "$temp_dir/pr.json" "$pr_json" || return 1
	_approval_snapshot_v2_write_json_file "$temp_dir/review-comments.json" "$review_comments_json" || return 1
	_approval_snapshot_v2_write_json_file "$temp_dir/reviews.json" "$reviews_json" || return 1

	jq -cS -n --arg repo "$normalized_slug" --arg empty "$empty_string" --argjson number "$target_number" \
		--slurpfile issue_input "$temp_dir/issue.json" --slurpfile pr_input "$temp_dir/pr.json" \
		--slurpfile comments_input "$temp_dir/comments.json" --slurpfile review_comments_input "$temp_dir/review-comments.json" \
		--slurpfile reviews_input "$temp_dir/reviews.json" --slurpfile linked_references_input "$temp_dir/linked-references.json" '
		($issue_input[0]) as $issue | ($pr_input[0]) as $pr |
		{
			schema: "aidevops-approval-snapshot/v2",
			target: {kind: "pr", repository: $repo, number: $number, id: $pr.id, node_id: $pr.node_id, issue_id: $issue.id},
			author: {
				id: ($pr.user.id // null), node_id: ($pr.user.node_id // $empty),
				login: ($pr.user.login // $empty), type: ($pr.user.type // $empty),
				association: ($pr.author_association // $empty)
			},
			created_at: ($pr.created_at // $empty),
			title: ($pr.title // $empty),
			body: ($pr.body // $empty),
			head: {
				sha: $pr.head.sha, ref: ($pr.head.ref // $empty),
				repository_id: ($pr.head.repo.id // null), repository: (($pr.head.repo.full_name // $empty) | ascii_downcase)
			},
			base: {
				ref: $pr.base.ref,
				repository_id: ($pr.base.repo.id // null), repository: (($pr.base.repo.full_name // $repo) | ascii_downcase)
			},
			comments: $comments_input[0],
			review_comments: $review_comments_input[0],
			reviews: $reviews_input[0],
			linked_references: $linked_references_input[0]
		}
	'
	return $?
)

approval_snapshot_v2_digest() {
	local snapshot_json="$1"
	local digest=""

	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$snapshot_json" | sha256sum | awk '{print $1}') || return 1
	elif command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$snapshot_json" | shasum -a 256 | awk '{print $1}') || return 1
	else
		return 1
	fi
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s\n' "$digest"
	return 0
}

approval_snapshot_v2_payload() (
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local issued_at="$4"
	local excluded_comment_id="${5:-}"
	local source_timestamp_profile="${6:-stable}"
	local snapshot_json="" digest="" normalized_slug=""
	local temp_dir=""

	snapshot_json=$(approval_snapshot_v2_build "$target_type" "$target_number" "$slug" "$excluded_comment_id" "$issued_at" "$source_timestamp_profile") || return 1
	digest=$(approval_snapshot_v2_digest "$snapshot_json") || return 1
	normalized_slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
	temp_dir=$(_approval_snapshot_v2_create_temp_dir) || return 1
	trap 'rm -rf "$temp_dir"' EXIT
	_approval_snapshot_v2_write_json_file "$temp_dir/snapshot.json" "$snapshot_json" || return 1
	jq -cS -n --arg type "$target_type" --arg repo "$normalized_slug" --argjson number "$target_number" \
		--arg issued "$issued_at" --arg digest "$digest" --slurpfile snapshot_input "$temp_dir/snapshot.json" '
		($snapshot_input[0]) as $snapshot |
		{
			schema: "aidevops-approval/v2",
			authority: (if $type == "pr" then "merge" else "development" end),
			issued_at: $issued,
			target: {kind: $type, repository: $repo, number: $number},
			snapshot_sha256: $digest,
			pr: (if $type == "pr" then {
				head_sha: $snapshot.head.sha,
				head_ref: $snapshot.head.ref,
				head_repository: $snapshot.head.repository,
				base_ref: $snapshot.base.ref,
				base_repository: $snapshot.base.repository
			} else null end)
		}
	'
	return $?
)
