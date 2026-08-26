#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# approval-helper-continuity.sh — Locked approval continuity verification.
# =============================================================================
# Sourced by approval-helper.sh after approval constants and snapshot helpers.
# Keeps lifecycle continuity checks separate from approval issuance and writes.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_APPROVAL_HELPER_CONTINUITY_LOADED:-}" ]] && return 0
_APPROVAL_HELPER_CONTINUITY_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_approval_continuity_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_approval_continuity_lib_path" == "${BASH_SOURCE[0]}" ]] && _approval_continuity_lib_path="."
	SCRIPT_DIR="$(cd "$_approval_continuity_lib_path" && pwd)"
	unset _approval_continuity_lib_path
fi

_approval_continuity_actor_authorized() {
	local slug="$1"
	local login="$2"
	local permission=""
	[[ "$login" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
	permission=$(gh api "repos/${slug}/collaborators/${login}/permission" --jq '.permission // "none"' 2>/dev/null) || return 2
	case "$permission" in
	admin | maintain | write) return 0 ;;
	esac
	return 1
}

_approval_continuity_is_repository_status_default() {
	local event="$1"
	local subject="$2"
	local actor="$3"
	local actor_id="$4"
	local actor_type="$5"
	[[ "$event" == "labeled" && "$subject" == "$_APPROVAL_AVAILABLE_LABEL" ]] || return 1
	[[ "$actor" == "github-actions[bot]" ]] || return 1
	[[ "$actor_id" == "$_APPROVAL_GITHUB_ACTIONS_BOT_ID" ]] || return 1
	[[ "$actor_type" == "Bot" ]] || return 1
	return 0
}

_approval_continuity_ordered_mutation_rows() {
	local timeline_pages="$1"
	local issued_at="$2"
	local approval_comment_id="$3"

	# #aidevops:trust-boundary — the signed approval comment is the stable
	# timeline anchor. Flatten every page, validate the complete mutation stream,
	# and sort by GitHub's stable (created_at, id) key before authorization.
	jq -r --arg issued "$issued_at" --argjson approval_id "$approval_comment_id" '
		def valid_id:
			type == "number" and . >= 0 and floor == .;
		def valid_timestamp:
			type == "string"
			and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
			and ((try (fromdateiso8601 | todateiso8601) catch "") == .);
		def lifecycle_mutation:
			(.event // "") as $event
			| ["assigned","unassigned","labeled","unlabeled","milestoned","demilestoned","closed","reopened","renamed","locked","unlocked","connected","disconnected","added_to_project","moved_columns_in_project","removed_from_project","transferred","converted_to_discussion","marked_as_duplicate","unmarked_as_duplicate","pinned","unpinned"]
			| index($event) != null;
		[.[][]?] as $events
		| [$events[] | select((.event // "") == "commented" and (.id // null) == $approval_id)] as $anchors
		| [$events[] | select(lifecycle_mutation)] as $mutations
		| if (($issued | valid_timestamp) | not)
			or ($anchors | length) != 1
			or (($anchors[0].id | valid_id) | not)
			or (($anchors[0].created_at | valid_timestamp) | not)
			or $anchors[0].created_at < $issued
			or any($mutations[]; ((.id // null) | valid_id) | not)
			or any($mutations[]; ((.created_at // "") | valid_timestamp) | not)
			or (($mutations + $anchors) | sort_by(.created_at, .id) | group_by([.created_at, .id]) | any(length > 1))
		then error("timeline ordering evidence is incomplete or ambiguous")
		else
			$anchors[0] as $anchor
			| $mutations
			| map(select(.created_at > $anchor.created_at or (.created_at == $anchor.created_at and .id > $anchor.id)))
			| sort_by(.created_at, .id)
			| .[]
			| [(.event // ""), (.actor.login // ""), (.label.name // .assignee.login // ""), ((.actor.id // "") | tostring), (.actor.type // "")]
			| @tsv
		end
	' <<<"$timeline_pages"
	return $?
}

_approval_continuity_lifecycle_change_allowed() {
	local signed_lifecycle="$1"
	local current_snapshot="$2"

	# #aidevops:trust-boundary — deterministic tier backfill may only select a
	# canonical workload tier. Status labels remain workflow metadata, but every
	# resulting timeline mutation still requires authorization during replay.
	jq -e --argjson signed "$signed_lifecycle" '
		def allowed_label: . == "needs-maintainer-review" or . == "auto-dispatch" or . == "status:available" or . == "status:queued" or . == "status:claimed" or . == "status:in-progress" or . == "status:in-review" or . == "status:done" or . == "status:blocked" or . == "tier:simple" or . == "tier:standard" or . == "tier:thinking";
		def tier_label: . == "tier:simple" or . == "tier:standard" or . == "tier:thinking";
		.lifecycle as $current |
		($current.labels | map(.name)) as $current_labels |
		($signed.labels | map(.name)) as $signed_labels |
		($current_labels - $signed_labels) as $added_labels |
		($signed_labels - $current_labels) as $removed_labels |
		([$added_labels[] | select(tier_label)] | length) as $added_tiers |
		([$removed_labels[] | select(tier_label)] | length) as $removed_tiers |
		([$signed_labels[] | select(tier_label)] | length) as $signed_tiers |
		([$current_labels[] | select(tier_label)] | length) as $current_tiers |
		$current.state == $signed.state
		and $current.state_reason == $signed.state_reason
		and $current.locked == $signed.locked
		and $current.active_lock_reason == $signed.active_lock_reason
		and $current.milestone == $signed.milestone
		and $current.lock_anchor == $signed.lock_anchor
		and ([$added_labels[], $removed_labels[]] | unique | all(allowed_label))
		and (if ($added_tiers + $removed_tiers) > 0 then $signed_tiers == 0 and $current_tiers == 1 and $added_tiers == 1 and $removed_tiers == 0 else true end)
		and ($current.assignees != $signed.assignees or $current.labels != $signed.labels)
	' <<<"$current_snapshot" >/dev/null 2>&1
	return $?
}

_approval_verify_locked_issue_continuity() {
	local payload="$1"
	local current_snapshot="$2"
	local signed_digest="$3"
	local slug="$4"
	local target_number="$5"
	local issued_at="$6"
	local approval_comment_id="$7"
	local signed_lifecycle="" current_anchor="" signed_anchor="" candidate="" candidate_digest=""
	local timeline_pages="" mutation_rows="" event="" actor="" subject="" actor_id="" actor_type="" actor_rc=0
	local signed_has_status=0 auto_dispatch_active=0 current_auto_dispatch=0 saw_status_mutation=0 saw_status_default=0

	# #aidevops:trust-boundary — no embedded lifecycle proof means this is a
	# legacy exact-snapshot approval, never continuity authority.
	signed_lifecycle=$(jq -c '.issue.lifecycle // empty' <<<"$payload" 2>/dev/null) || return 1
	[[ -n "$signed_lifecycle" ]] || return 1
	if ! jq -e --arg object "$APPROVAL_JSON_OBJECT" '.locked == true and (.lock_anchor | type == $object)' <<<"$signed_lifecycle" >/dev/null 2>&1; then
		return 1
	fi
	signed_anchor=$(jq -c '.lock_anchor' <<<"$signed_lifecycle") || return 1
	if jq -e '[.labels[]?.name | select(startswith("status:"))] | length > 0' <<<"$signed_lifecycle" >/dev/null 2>&1; then
		signed_has_status=1
	fi
	if jq -e --arg auto "$_APPROVAL_AUTO_DISPATCH_LABEL" 'any(.labels[]?.name; . == $auto)' <<<"$signed_lifecycle" >/dev/null 2>&1; then
		auto_dispatch_active=1
	fi
	if jq -e --arg auto "$_APPROVAL_AUTO_DISPATCH_LABEL" 'any(.lifecycle.labels[]?.name; . == $auto)' <<<"$current_snapshot" >/dev/null 2>&1; then
		current_auto_dispatch=1
	fi
	current_anchor=$(jq -c '.lifecycle.lock_anchor // empty' <<<"$current_snapshot") || return 1
	[[ -n "$current_anchor" && "$current_anchor" == "$signed_anchor" ]] || return 1
	if ! jq -e '.lifecycle.locked == true' <<<"$current_snapshot" >/dev/null 2>&1; then
		return 1
	fi

	# Replacing only lifecycle metadata must recreate the signed digest. This
	# proves title, body, comments, references, identity, and all scope-bearing
	# bytes remain exactly as reviewed.
	candidate=$(jq -cS --argjson lifecycle "$signed_lifecycle" '.lifecycle = $lifecycle' <<<"$current_snapshot") || return 1
	candidate_digest=$(approval_snapshot_v2_digest "$candidate") || return 2
	[[ "$candidate_digest" == "$signed_digest" ]] || return 1
	if ! _approval_continuity_lifecycle_change_allowed "$signed_lifecycle" "$current_snapshot"; then
		return 1
	fi

	timeline_pages=$(_approval_snapshot_v2_fetch_pages "repos/${slug}/issues/${target_number}/timeline?per_page=100") || return 2
	mutation_rows=$(_approval_continuity_ordered_mutation_rows "$timeline_pages" "$issued_at" "$approval_comment_id" 2>/dev/null) || return 2
	[[ -n "$mutation_rows" ]] || return 1

	while IFS=$'\t' read -r event actor subject actor_id actor_type; do
		[[ -n "$event" ]] || continue
		case "$event:$subject" in
		assigned:* | unassigned:* | labeled:needs-maintainer-review | unlabeled:needs-maintainer-review | labeled:auto-dispatch | unlabeled:auto-dispatch | labeled:status:available | unlabeled:status:available | labeled:status:queued | unlabeled:status:queued | labeled:status:claimed | unlabeled:status:claimed | labeled:status:in-progress | unlabeled:status:in-progress | labeled:status:in-review | unlabeled:status:in-review | labeled:status:done | unlabeled:status:done | labeled:status:blocked | unlabeled:status:blocked | labeled:tier:simple | unlabeled:tier:simple | labeled:tier:standard | unlabeled:tier:standard | labeled:tier:thinking | unlabeled:tier:thinking) ;;
		*) return 1 ;;
		esac
		# #aidevops:trust-boundary — GitHub's official Actions bot has no
		# collaborator permission. Accept its single non-scope-bearing default only
		# for the expected no-status handoff sequence: an authorized maintainer first
		# exposed auto-dispatch and no status mutation has occurred. The immutable
		# bot ID/type prevents lookalikes; this grants no generic workflow authority.
		if _approval_continuity_is_repository_status_default "$event" "$subject" "$actor" "$actor_id" "$actor_type"; then
			[[ "$signed_has_status" -eq 0 && "$auto_dispatch_active" -eq 1 && "$saw_status_mutation" -eq 0 && "$saw_status_default" -eq 0 ]] || return 1
			saw_status_default=1
			saw_status_mutation=1
			continue
		fi
		actor_rc=0
		_approval_continuity_actor_authorized "$slug" "$actor" || actor_rc=$?
		[[ "$actor_rc" -eq 0 ]] || {
			[[ "$actor_rc" -eq 2 ]] && return 2
			return 1
		}
		[[ "$event:$subject" == "labeled:$_APPROVAL_AUTO_DISPATCH_LABEL" ]] && auto_dispatch_active=1
		[[ "$event:$subject" == "unlabeled:$_APPROVAL_AUTO_DISPATCH_LABEL" ]] && auto_dispatch_active=0
		[[ "$subject" == status:* ]] && saw_status_mutation=1
	done <<<"$mutation_rows"
	[[ "$auto_dispatch_active" -eq "$current_auto_dispatch" ]] || return 1
	return 0
}

_approval_classify_digest_mismatch() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local comment_id="$4"
	local issued_at="$5"
	local issue_lifecycle_profile="$6"
	local payload="$7"
	local snapshot_json="$8"
	local signed_digest="$9"
	local legacy_snapshot_json="" legacy_digest="" continuity_rc=0

	legacy_snapshot_json=$(approval_snapshot_v2_build "$target_type" "$target_number" "$slug" "$comment_id" "$issued_at" "$APPROVAL_SNAPSHOT_PROFILE_LEGACY" "$issue_lifecycle_profile") || {
		printf 'API_ERROR\n'
		return 0
	}
	legacy_digest=$(approval_snapshot_v2_digest "$legacy_snapshot_json") || {
		printf 'API_ERROR\n'
		return 0
	}
	if [[ "$legacy_digest" == "$signed_digest" ]]; then
		printf 'LEGACY_MATCH\n'
		return 0
	fi
	if [[ "$target_type" == "$APPROVAL_TARGET_ISSUE" ]]; then
		_approval_verify_locked_issue_continuity "$payload" "$snapshot_json" "$signed_digest" "$slug" "$target_number" "$issued_at" "$comment_id" || continuity_rc=$?
		if [[ "$continuity_rc" -eq 0 ]]; then
			printf 'APPROVAL_REASON: proven-locked-continuity\n' >&2
			printf 'VERIFIED\n'
			return 0
		fi
		if [[ "$continuity_rc" -eq 2 ]]; then
			printf 'APPROVAL_REASON: continuity-api-uncertain\n' >&2
			printf 'API_ERROR\n'
			return 0
		fi
	fi
	printf 'APPROVAL_REASON: stale-or-unproven-continuity\n' >&2
	printf 'STALE_APPROVAL\n'
	return 0
}
