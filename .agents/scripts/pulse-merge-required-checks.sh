#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-required-checks.sh — required-check terminal-state classifiers.

[[ -n "${_PULSE_MERGE_REQUIRED_CHECKS_LOADED:-}" ]] && return 0
_PULSE_MERGE_REQUIRED_CHECKS_LOADED=1
_PULSE_MERGE_REQUIRED_CHECKS_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib/descriptor-safe-log.sh
source "${_PULSE_MERGE_REQUIRED_CHECKS_DIR}/lib/descriptor-safe-log.sh"
PMRC_CHECK_COMPLETED="completed"
PMRC_CHECK_SUCCESS="success"
PMRC_CHECK_FAILURE="failure"
PMRC_BOOL_TRUE="true"
PMRC_JSON_ARRAY="array"
PMRC_JSON_NUMBER="number"
PMRC_JSON_OBJECT="object"
PMRC_JSON_STRING="string"
PMRC_RULESET_ACTIVE="active"
PMRC_RULESET_BRANCH="branch"
PMRC_RULESET_DISABLED="disabled"
PMRC_RULESET_EVALUATE="evaluate"
PMRC_RULESET_PUSH="push"
PMRC_RULESET_TAG="tag"
PMRC_MAINTAINER_GATE="maintainer-gate"
PMRC_MAINTAINER_GATE_DISPLAY="Maintainer Review & Assignee Gate"
PMRC_MAINTAINER_GATE_WORKFLOW="gate / Maintainer Review & Assignee Gate"
PMRC_REVIEW_BOT_GATE="review-bot-gate"
PMRC_REVIEW_BOT_GATE_WORKFLOW="gate / review-bot-gate"
PMRC_SUBJECT_HEAD_PREFIX="head "
PMRC_SUBJECT_PR_PREFIX="PR #"
PMRC_BLOCKER_REVIEW_BOT_THREADS="review-bot-threads"
PMRC_BLOCKER_REQUIRED_REVIEW_THREADS="required-review-threads"
PMRC_BLOCKER_MERGE_AUTHORITY="merge-authority"
PMRC_BLOCKER_REVIEW_GATE="review-gate"
PMRC_BLOCKER_CHECKS_ACTIVE="checks-active"
PMRC_BLOCKER_CHECKS_FAILED="checks-failed"
PMRC_BLOCKER_QUIET_PERIOD="quiet-period"
PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE="snapshot-unavailable"
PMRC_BLOCKER_HEAD_CHANGED="head-changed"
: "${_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON:=[]}"
: "${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:=}"

_pmrc_gh_read() {
	local rc=0
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}

_pmrc_cache_key() {
	local raw_key="$1"
	local safe_key=""
	safe_key=$(printf '%s' "$raw_key" | tr -c '[:alnum:]._-' '_')
	[[ -n "$safe_key" ]] || safe_key="empty"
	printf '%s\n' "$safe_key"
	return 0
}

_pmrc_private_plan_feature_unavailable() {
	local response="$1"
	[[ "$response" == *"Upgrade to GitHub Pro or make this repository public to enable this feature."* ]] || return 1
	[[ "$response" == *"HTTP 403"* ]] || return 1
	return 0
}

_pmrc_rulesets_list_schema_valid() {
	local rulesets_json="$1"
	printf '%s' "$rulesets_json" | jq -e \
		--arg active "$PMRC_RULESET_ACTIVE" \
		--arg array "$PMRC_JSON_ARRAY" \
		--arg branch "$PMRC_RULESET_BRANCH" \
		--arg disabled "$PMRC_RULESET_DISABLED" \
		--arg evaluate "$PMRC_RULESET_EVALUATE" \
		--arg number "$PMRC_JSON_NUMBER" \
		--arg obj "$PMRC_JSON_OBJECT" \
		--arg push "$PMRC_RULESET_PUSH" \
		--arg string "$PMRC_JSON_STRING" \
		--arg tag "$PMRC_RULESET_TAG" '
		type == $array and
		all(.[];
			type == $obj and
			(.id | type == $number and . > 0) and
			(.enforcement as $value |
				($value | type == $string) and
				([$active, $disabled, $evaluate] | index($value) != null)) and
			(.target as $value |
				($value | type == $string) and
				([$branch, $push, $tag] | index($value) != null)))
	' >/dev/null 2>&1
	return $?
}

_pmrc_branch_ruleset_detail_schema_valid() {
	local detail="$1"
	local expected_id="$2"
	printf '%s' "$detail" | jq -e \
		--arg active "$PMRC_RULESET_ACTIVE" \
		--arg array "$PMRC_JSON_ARRAY" \
		--arg branch "$PMRC_RULESET_BRANCH" \
		--argjson expected_id "$expected_id" \
		--arg obj "$PMRC_JSON_OBJECT" \
		--arg number "$PMRC_JSON_NUMBER" \
		--arg required_status_checks "required_status_checks" \
		--arg string "$PMRC_JSON_STRING" '
		type == $obj and
		(.id | type == $number and . == $expected_id) and
		.enforcement == $active and
		.target == $branch and
		(.conditions.ref_name.include | type == $array) and
		all(.conditions.ref_name.include[]; type == $string) and
		((.conditions.ref_name.exclude // []) | type == $array) and
		all((.conditions.ref_name.exclude // [])[]; type == $string) and
		(.rules | type == $array) and
		all(.rules[];
			type == $obj and (.type | type == $string) and
			(if .type == $required_status_checks then
				(.parameters.required_status_checks | type == $array) and
				all(.parameters.required_status_checks[];
					type == $obj and
					((.context // .name // "") | type == $string and length > 0))
			else true end))
	' >/dev/null 2>&1
	return $?
}

#######################################
# Return whether a repository-ruleset ref pattern applies to the default branch.
# Rulesets may use exact refs, GitHub tokens, or simple branch globs.
#
# Args: $1=pattern, $2=default_branch
# Returns: 0=matches default branch, 1=does not match
#######################################
_ruleset_ref_matches_default_branch() {
	local pattern="$1"
	local default_branch="$2"
	local default_ref="refs/heads/${default_branch}"
	local branch_pattern="${pattern}"

	case "$pattern" in
	"~ALL" | "~DEFAULT_BRANCH" | "$default_ref" | "$default_branch")
		return 0
		;;
	esac
	case "$pattern" in
	refs/heads/*)
		branch_pattern="${pattern#refs/heads/}"
		;;
	esac

	case "$pattern" in
	*"*"*)
		# shellcheck disable=SC2254 # Intentionally treat ruleset branch globs as patterns.
		case "$default_ref" in
		$pattern)
			return 0
			;;
		esac
		# shellcheck disable=SC2254 # Intentionally treat ruleset branch globs as patterns.
		case "$default_branch" in
		$branch_pattern)
			return 0
			;;
		esac
		;;
	esac

	return 1
}

#######################################
# Resolve required status check contexts from active repository rulesets that
# match the default branch.
#
# Args: $1=repo_slug, $2=default_branch
# Stdout: newline-delimited contexts
# Returns: 0=resolved, 1=API/parse error
#######################################
_required_contexts_from_rulesets_for_default_branch() {
	local repo_slug="$1"
	local default_branch="$2"
	local rulesets_json="" rulesets_rc=0

	rulesets_json=$(_pmrc_gh_read gh api "repos/${repo_slug}/rulesets" 2>&1) || rulesets_rc=$?
	if [[ "$rulesets_rc" -ne 0 ]]; then
		if _pmrc_private_plan_feature_unavailable "$rulesets_json"; then
			aidevops_log_line "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: rulesets unavailable for ${repo_slug} on the private plan (HTTP 403) — empty contexts (GH#29484)"
			return 0
		fi
		aidevops_log_line "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: rulesets list failed for ${repo_slug} — caller will fail closed (GH#23019)"
		return 1
	fi
	if ! _pmrc_rulesets_list_schema_valid "$rulesets_json"; then
		aidevops_log_line "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: rulesets list parse failed for ${repo_slug} — caller will fail closed (GH#23019, GH#28864)"
		return 1
	fi
	[[ "$rulesets_json" != "[]" ]] || return 0

	local active_ids=""
	active_ids=$(printf '%s' "$rulesets_json" | jq -r \
		--arg active "$PMRC_RULESET_ACTIVE" --arg branch "$PMRC_RULESET_BRANCH" \
		'.[] | select(.enforcement == $active and .target == $branch) | .id' 2>/dev/null) || {
		aidevops_log_line "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: rulesets list parse failed for ${repo_slug} — caller will fail closed (GH#23019)"
		return 1
	}
	[[ -n "$active_ids" ]] || return 0

	local contexts_tmp=""
	contexts_tmp=$(mktemp) || {
		aidevops_log_line "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: mktemp failed for ${repo_slug} — caller will fail closed (GH#23019)"
		return 1
	}

	local id="" detail="" include_patterns="" exclude_patterns="" pattern=""
	local matches_default=0 excluded_default=0 contexts=""
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		detail=$(_pmrc_gh_read gh api "repos/${repo_slug}/rulesets/${id}" 2>/dev/null) || {
			aidevops_log_line "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: ruleset detail ${id} failed for ${repo_slug} — caller will fail closed (GH#23019)"
			rm -f "$contexts_tmp"
			return 1
		}
		if ! _pmrc_branch_ruleset_detail_schema_valid "$detail" "$id"; then
			aidevops_log_line "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: ruleset detail ${id} parse failed for ${repo_slug} — caller will fail closed (GH#23019, GH#28864)"
			rm -f "$contexts_tmp"
			return 1
		fi

		include_patterns=$(printf '%s' "$detail" | jq -r '.conditions.ref_name.include // [] | .[]' 2>/dev/null) || {
			aidevops_log_line "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: ruleset detail ${id} parse failed for ${repo_slug} — caller will fail closed (GH#23019)"
			rm -f "$contexts_tmp"
			return 1
		}
		exclude_patterns=$(printf '%s' "$detail" | jq -r '.conditions.ref_name.exclude // [] | .[]' 2>/dev/null) || {
			aidevops_log_line "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: ruleset detail ${id} exclude parse failed for ${repo_slug} — caller will fail closed (GH#23019)"
			rm -f "$contexts_tmp"
			return 1
		}

		matches_default=0
		while IFS= read -r pattern; do
			[[ -n "$pattern" ]] || continue
			if _ruleset_ref_matches_default_branch "$pattern" "$default_branch"; then
				matches_default=1
				break
			fi
		done <<<"$include_patterns"
		[[ "$matches_default" -eq 1 ]] || continue

		excluded_default=0
		while IFS= read -r pattern; do
			[[ -n "$pattern" ]] || continue
			if _ruleset_ref_matches_default_branch "$pattern" "$default_branch"; then
				excluded_default=1
				break
			fi
		done <<<"$exclude_patterns"
		[[ "$excluded_default" -eq 0 ]] || continue

		contexts=$(printf '%s' "$detail" | jq -r '.rules[]? | select(.type == "required_status_checks") | (.parameters.required_status_checks // [])[]? | (.context // .name // empty)' 2>/dev/null) || {
			aidevops_log_line "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: required-check parse failed for ruleset ${id} in ${repo_slug} — caller will fail closed (GH#23019)"
			rm -f "$contexts_tmp"
			return 1
		}
		[[ -n "$contexts" ]] && printf '%s\n' "$contexts" >>"$contexts_tmp"
	done <<<"$active_ids"

	if [[ -s "$contexts_tmp" ]]; then
		sort -u "$contexts_tmp"
	fi
	rm -f "$contexts_tmp"
	return 0
}

#######################################
# Resolve required status check contexts for a repository's default branch from
# classic branch protection plus active matching repository rulesets.
#
# Args: $1=repo_slug
# Stdout: newline-delimited contexts; empty means no configured required checks
# Returns: 0=resolved, 1=API/parse error
#######################################
_required_contexts_for_default_branch_uncached() {
	local repo_slug="$1"
	local default_branch="" default_branch_rc=0
	default_branch=$(_pmrc_gh_read gh api "repos/${repo_slug}" --jq '.default_branch' 2>/dev/null) || default_branch_rc=$?
	if [[ "$default_branch_rc" -ne 0 || -z "$default_branch" ]]; then
		aidevops_log_line "[pulse-merge] _required_contexts_for_default_branch: failed to resolve default branch for ${repo_slug} — caller will fail closed (t2922)"
		return 1
	fi

	local protection_resp="" protection_rc=0
	protection_resp=$(AIDEVOPS_GH_QUOTA_COST=1 \
		AIDEVOPS_GH_ROUTE_DECISION="pulse-branch-protection-required-contexts-rest" \
		_pmrc_gh_read gh api \
		"repos/${repo_slug}/branches/${default_branch}/protection/required_status_checks" \
		2>&1) || protection_rc=$?
	if [[ "$protection_rc" -ne 0 ]]; then
		local classic_unavailable_reason=""
		if grep -qi 'HTTP 404\|Not Found' <<<"$protection_resp"; then
			classic_unavailable_reason="HTTP 404"
		elif _pmrc_private_plan_feature_unavailable "$protection_resp"; then
			classic_unavailable_reason="private-plan unavailable (HTTP 403)"
		fi
		if [[ -n "$classic_unavailable_reason" ]]; then
			local ruleset_contexts_unavailable=""
			ruleset_contexts_unavailable=$(_required_contexts_from_rulesets_for_default_branch "$repo_slug" "$default_branch") || return 1
			if [[ -n "$ruleset_contexts_unavailable" ]]; then
				aidevops_log_line "[pulse-merge] _required_contexts_for_default_branch: no classic branch protection on ${repo_slug} (${classic_unavailable_reason}), but active rulesets require contexts (GH#23019, GH#28864)"
				printf '%s\n' "$ruleset_contexts_unavailable"
				return 0
			fi
			aidevops_log_line "[pulse-merge] _required_contexts_for_default_branch: no classic branch protection or required ruleset contexts on ${repo_slug} default branch (${classic_unavailable_reason}) — empty contexts (t3193, GH#23019, GH#28864)"
			return 0
		fi
		aidevops_log_line "[pulse-merge] _required_contexts_for_default_branch: branch protection API failed for ${repo_slug} (exit ${protection_rc}) — caller will fail closed (t2922)"
		return 1
	fi

	local classic_contexts="" ruleset_contexts=""
	classic_contexts=$(printf '%s' "$protection_resp" | jq -r '(.contexts // [])[], (.checks // [])[].context? // empty' 2>/dev/null) || {
		aidevops_log_line "[pulse-merge] _required_contexts_for_default_branch: branch protection parse failed for ${repo_slug} — caller will fail closed (t2922)"
		return 1
	}
	ruleset_contexts=$(_required_contexts_from_rulesets_for_default_branch "$repo_slug" "$default_branch") || return 1
	if [[ -n "$ruleset_contexts" ]]; then
		aidevops_log_line "[pulse-merge] _required_contexts_for_default_branch: active rulesets add required contexts for ${repo_slug} (GH#23019)"
	fi

	printf '%s\n%s\n' "$classic_contexts" "$ruleset_contexts" | awk 'NF && !seen[$0]++'
	return 0
}

_required_contexts_for_default_branch() {
	local repo_slug="$1"
	local cache_dir="${AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR:-}"
	local cache_key="" cache_body_file="" cache_rc_file="" cache_rc=""
	local contexts="" rc=0

	if [[ -n "$cache_dir" && -d "$cache_dir" ]]; then
		cache_key=$(_pmrc_cache_key "$repo_slug")
		cache_body_file="${cache_dir}/${cache_key}.body"
		cache_rc_file="${cache_dir}/${cache_key}.rc"
		if [[ -f "$cache_rc_file" && -f "$cache_body_file" ]]; then
			cache_rc=$(<"$cache_rc_file")
			[[ "$cache_rc" =~ ^[0-9]+$ ]] || cache_rc=1
			if [[ "$cache_rc" -eq 0 && -s "$cache_body_file" ]]; then
				while IFS= read -r contexts; do
					printf '%s\n' "$contexts"
				done <"$cache_body_file"
			fi
			return "$cache_rc"
		fi
	fi

	contexts=$(_required_contexts_for_default_branch_uncached "$repo_slug") || rc=$?
	if [[ -n "$cache_body_file" && -n "$cache_rc_file" ]]; then
		printf '%s\n' "$rc" >"$cache_rc_file"
		if [[ -n "$contexts" ]]; then
			printf '%s\n' "$contexts" >"$cache_body_file"
		else
			: >"$cache_body_file"
		fi
	fi
	if [[ "$rc" -eq 0 && -n "$contexts" ]]; then
		printf '%s\n' "$contexts"
	fi
	return "$rc"
}

_pmrc_iso_to_epoch() {
	local iso="$1"
	local epoch=""
	[[ -n "$iso" ]] || return 1
	epoch=$(date -u -d "$iso" +%s 2>/dev/null ||
		TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null) || epoch=""
	[[ "$epoch" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$epoch"
	return 0
}

_pmrc_snapshot_log_failure() {
	local repo_slug="$1"
	local subject="$2"
	local stage="$3"
	aidevops_log_line "[pulse-merge] pre-merge snapshot: ${stage} failed for ${subject} in ${repo_slug} — failing closed (GH#28209)"
	return 0
}

_pmrc_record_preflight_check_mismatch() {
	if declare -F gh_record_efficiency_evidence >/dev/null 2>&1; then
		gh_record_efficiency_evidence guardrails.required_check_merge_preflight_mismatches 1 2>/dev/null || true
		# This live action-boundary snapshot runs only after the earlier merge
		# readiness path was positive. A new blocker therefore proves that stale
		# positive evidence reached the final preflight, even though the merge is
		# correctly stopped here.
		gh_record_efficiency_evidence guardrails.stale_positive_decisions 1 2>/dev/null || true
	fi
	return 0
}

_pmrc_normalize_snapshot_checks_json() {
	local repo_slug="$1"
	local head_sha="$2"
	local checks_json=""

	checks_json=$(jq -s \
		--arg completed "$PMRC_CHECK_COMPLETED" --arg success "$PMRC_CHECK_SUCCESS" --arg failure "$PMRC_CHECK_FAILURE" \
		--arg array_type "$PMRC_JSON_ARRAY" --arg object_type "$PMRC_JSON_OBJECT" \
		--arg skipped "skipped" --arg maintainer "$PMRC_MAINTAINER_GATE" --arg maintainer_display "$PMRC_MAINTAINER_GATE_DISPLAY" \
		--arg maintainer_workflow "$PMRC_MAINTAINER_GATE_WORKFLOW" \
		--arg review_gate "$PMRC_REVIEW_BOT_GATE" --arg review_gate_workflow "$PMRC_REVIEW_BOT_GATE_WORKFLOW" '
		if length != 2 or (.[0] | type) != $array_type or (.[1] | type) != $object_type
		then error("invalid check-runs or commit-status response")
		else . end |
		.[0] as $pages | .[1] as $statuses |
		"pending" as $pending | "in_progress" as $in_progress |
		"error" as $error |
		[
			$pages[]?.check_runs[]? | {
				source: "check_run",
				name: (.name // ""),
				app_slug: (.app.slug // ""),
				status: ((.status // "") | ascii_downcase),
				conclusion: ((.conclusion // "") | ascii_downcase),
				link: (.details_url // .html_url // ""),
				observed_at: (.completed_at // .started_at // "")
			}
		] + [
			$statuses.statuses[]? | ((.state // "") | ascii_downcase) as $state | {
				source: "commit_status",
				name: (.context // ""),
				app_slug: "",
				status: (if $state == $pending then $in_progress else $completed end),
				conclusion: (if $state == $success then $success elif ($state == $failure or $state == $error) then $failure else "" end),
				link: (.target_url // ""),
				observed_at: (.updated_at // .created_at // "")
			}
		]
		| map(select(.name != ""))
		| sort_by(.source, .name, .observed_at)
		| group_by([.source, .name])
		| map(
			# Preserve the latest executed result so skipped reruns cannot hide advisory companions.
			. as $runs
			| ([$runs[] | select(.conclusion != $skipped)] | last) as $executed
			| $executed // last
		)
		| map(. + {
			family: (
				if (.name == $maintainer or .name == $maintainer_display or .name == $maintainer_workflow) then $maintainer
				elif (.name == $review_gate or .name == $review_gate_workflow) then $review_gate
				else .name end
			),
			family_key: (
				if (.name == $maintainer or .name == $maintainer_display or .name == $maintainer_workflow) then $maintainer
				elif (.name == $review_gate or .name == $review_gate_workflow) then $review_gate
				else (.source + "\u0000" + .name) end
			)
		})
		| sort_by(.family_key, .name, .source)
		| group_by(.family_key)
		| map(
			. as $members
			| .[0].family as $family
			| if ($family == $maintainer or $family == $review_gate) then
				# The stable branch-protection context is authoritative when present.
				# The explicit review-gate commit status is its stable context; legacy
				# workflow aliases remain fallback evidence only. This prevents a stale
				# failed or cancelled caller from overriding a newer stable result.
				([$members[] | select(
					($family == $maintainer and .name == $maintainer)
					or ($family == $review_gate and .source == "commit_status" and .name == $review_gate)
				)] | sort_by(.observed_at)) as $stable
				| (if ($stable | length) > 0 then $stable else ($members | sort_by(.observed_at)) end) as $effective
				| {
					name: $family,
					family: $family,
					source: "logical_family",
					status: (if any($effective[]; .status != $completed) then $in_progress else $completed end),
					conclusion: (
						if any($effective[]; (.conclusion == $failure or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure")) then $failure
						elif ($family == $review_gate and all($effective[]; .conclusion == $success)) then $success
						elif ($family == $maintainer and all($effective[]; (.conclusion == $success or .conclusion == "neutral" or .conclusion == $skipped))) then $success
						else "" end
					),
					app_slug: ([$effective[]?.app_slug | select(. != "")] | first // ""),
					observed_at: ([$effective[]?.observed_at | select(. != "")] | max // ""),
					members: [$members[] | {name, source, app_slug, status, conclusion, link, observed_at}]
				} else
				($members | sort_by(.observed_at) | last) as $latest
				| ($latest | del(.family_key)) + {members: [$members[] | {name, source, app_slug, status, conclusion, link, observed_at}]}
			end
		)
		| sort_by(.name)
	' 2>/dev/null) || {
		_pmrc_snapshot_log_failure "$repo_slug" "${PMRC_SUBJECT_HEAD_PREFIX}${head_sha:0:12}" "check-set parse"
		return 1
	}
	printf '%s\n' "$checks_json"
	return 0
}

_pmrc_snapshot_checks_json() {
	local repo_slug="$1"
	local head_sha="$2"
	local runs_pages="" statuses_json="" checks_json=""

	runs_pages=$(_pmrc_gh_read gh api "repos/${repo_slug}/commits/${head_sha}/check-runs?per_page=100" \
		--paginate --slurp 2>/dev/null) || {
		_pmrc_snapshot_log_failure "$repo_slug" "${PMRC_SUBJECT_HEAD_PREFIX}${head_sha:0:12}" "check-runs fetch"
		return 1
	}
	statuses_json=$(_pmrc_gh_read gh api "repos/${repo_slug}/commits/${head_sha}/status" 2>/dev/null) || {
		_pmrc_snapshot_log_failure "$repo_slug" "${PMRC_SUBJECT_HEAD_PREFIX}${head_sha:0:12}" "commit-status fetch"
		return 1
	}
	# Stream API documents over stdin instead of passing large check-run payloads
	# through --argjson, which can exceed the OS per-argument limit (GH#28164).
	checks_json=$(printf '%s\n%s\n' "$runs_pages" "$statuses_json" |
		_pmrc_normalize_snapshot_checks_json "$repo_slug" "$head_sha") || return 1
	printf '%s\n' "$checks_json"
	return 0
}

_pmrc_snapshot_bot_activity_json() {
	local repo_slug="$1"
	local pr_number="$2"
	local reviews="" issue_comments="" inline_comments="" activity=""
	# Retain gemini-code-assist only for historical review evidence.
	local bot_re="coderabbitai|gemini-code-assist|augment-code|augmentcode|copilot"

	reviews=$(_pmrc_gh_read gh api "repos/${repo_slug}/pulls/${pr_number}/reviews?per_page=100" \
		--paginate --slurp 2>/dev/null) || {
		_pmrc_snapshot_log_failure "$repo_slug" "${PMRC_SUBJECT_PR_PREFIX}${pr_number}" "reviews fetch"
		return 1
	}
	issue_comments=$(_pmrc_gh_read gh api "repos/${repo_slug}/issues/${pr_number}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || {
		_pmrc_snapshot_log_failure "$repo_slug" "${PMRC_SUBJECT_PR_PREFIX}${pr_number}" "issue-comments fetch"
		return 1
	}
	inline_comments=$(_pmrc_gh_read gh api "repos/${repo_slug}/pulls/${pr_number}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || {
		_pmrc_snapshot_log_failure "$repo_slug" "${PMRC_SUBJECT_PR_PREFIX}${pr_number}" "inline-comments fetch"
		return 1
	}
	# Stream all three paginated API documents over stdin. Review histories can
	# exceed Linux MAX_ARG_STRLEN, so none of these payloads may enter jq argv.
	activity=$(printf '%s\n%s\n%s\n' "$reviews" "$issue_comments" "$inline_comments" | jq -s \
		--arg bots "$bot_re" --arg array_type "$PMRC_JSON_ARRAY" '
		if length != 3
			or any(.[]; type != $array_type)
			or any(.[][]; type != $array_type)
		then error("invalid paginated bot-activity response")
		else . end |
		[
			.[0][][]?, .[1][][]?, .[2][][]?
			| select((.user.login // "") | test($bots; "i"))
			| (.updated_at // .submitted_at // .created_at // "")
			| select(. != "")
		] as $events
		| {count: ($events | length), latest_at: ($events | max // "")}
	' 2>/dev/null) || {
		_pmrc_snapshot_log_failure "$repo_slug" "${PMRC_SUBJECT_PR_PREFIX}${pr_number}" "bot-activity parse"
		return 1
	}
	printf '%s\n' "$activity"
	return 0
}

#######################################
# Resolve whether active rulesets applying to a PR base branch require every
# review thread to be resolved. GitHub exposes the effective rules for a branch,
# so this does not rely on user-defined ruleset names or duplicate ref matching.
#
# Args: $1=repo_slug, $2=base_branch
# Stdout: true or false
# Returns: 0=requirement resolved, 1=API/parse error
#######################################
_pmrc_review_thread_resolution_required() {
	local repo_slug="$1"
	local base_branch="$2"
	local encoded_branch="" rules_json="" required=""

	[[ -n "$repo_slug" && -n "$base_branch" ]] || return 1
	encoded_branch=$(jq -nr --arg branch "$base_branch" '$branch | @uri') || return 1
	[[ -n "$encoded_branch" ]] || return 1
	rules_json=$(AIDEVOPS_GH_QUOTA_COST=1 \
		AIDEVOPS_GH_ROUTE_DECISION="pulse-effective-rules-rest" \
		_pmrc_gh_read gh api "repos/${repo_slug}/rules/branches/${encoded_branch}" 2>/dev/null) || {
		aidevops_log_line "[pulse-merge] pre-merge snapshot: effective rules fetch failed for ${repo_slug} branch ${base_branch} — failing closed (GH#28130)"
		return 1
	}
	# shellcheck disable=SC2016 # jq program, not a shell interpolation context.
	required=$(aidevops_run_with_log_stderr jq -r --arg array_type "$PMRC_JSON_ARRAY" '
		if type != $array_type then error("effective rules response must be an array")
		else [
			.[]?
			| select(.type == "pull_request")
			| (.parameters?.required_review_thread_resolution? // false)
		] | any
		end
	' <<<"$rules_json") || {
		aidevops_log_line "[pulse-merge] pre-merge snapshot: effective rules parse failed for ${repo_slug} branch ${base_branch} — failing closed (GH#28130)"
		return 1
	}
	case "$required" in
	true | false) printf '%s\n' "$required" ;;
	*) return 1 ;;
	esac
	return 0
}

_pmrc_snapshot_review_threads_clear() {
	local repo_slug="$1"
	local pr_number="$2"
	local base_branch="$3"
	local owner="${repo_slug%%/*}" name="${repo_slug##*/}" response="" counts="" has_next=""
	local total_count="" bot_count="" resolution_required="" reported_cost=""
	# Retain gemini-code-assist so unresolved historical bot threads stay typed.
	local bot_re="coderabbitai|gemini-code-assist|augment-code|augmentcode|copilot"

	# This fixed query has a documented/calibrated GraphQL cost of one point.
	# Request the operation-owned cost in the same response and fail closed if
	# GitHub ever changes that contract; exact-capture telemetry can therefore
	# attribute this otherwise irreducible GraphQL review-thread read without a
	# racy before/after pool delta (GH#27777).
	# shellcheck disable=SC2016
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 AIDEVOPS_GH_ROUTE_DECISION="pulse-review-threads-exact-cost" \
		_pmrc_gh_read gh api graphql -F owner="$owner" -F name="$name" -F pr="$pr_number" -f query='
		query($owner: String!, $name: String!, $pr: Int!) {
			repository(owner: $owner, name: $name) {
				pullRequest(number: $pr) {
					reviewThreads(first: 100) {
						pageInfo { hasNextPage }
						nodes { isResolved comments(first: 1) { nodes { author { login } } } }
					}
				}
			}
			rateLimit { cost }
		}
	' 2>/dev/null) || return 1
	[[ -n "$response" ]] || return 1
	if ! printf '%s' "$response" | jq -e 'try (.data.repository.pullRequest != null) catch false' >/dev/null; then
		return 1
	fi
	reported_cost=$(printf '%s' "$response" | jq -r '.data.rateLimit.cost // empty') || return 1
	if [[ "$reported_cost" != "1" ]]; then
		aidevops_log_line "[pulse-merge] pre-merge snapshot: review-thread GraphQL cost contract changed for ${repo_slug} PR #${pr_number} — failing closed (GH#27777)"
		return 1
	fi
	has_next=$(printf '%s' "$response" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false') || return 1
	[[ "$has_next" == "false" ]] || return 1
	counts=$(printf '%s' "$response" | jq -r --arg bots "$bot_re" '
		[.data.repository.pullRequest.reviewThreads.nodes[]?
		| select((.isResolved // false) == false)] as $unresolved
		| [
			($unresolved | length),
			([$unresolved[]
				| select((.comments.nodes[0].author.login // "") | test($bots; "i"))
			] | length)
		] | @tsv
	') || return 1
	IFS=$'\t' read -r total_count bot_count <<<"$counts"
	[[ "$total_count" =~ ^[0-9]+$ && "$bot_count" =~ ^[0-9]+$ ]] || return 1
	if [[ "$bot_count" -gt 0 ]]; then
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_REVIEW_BOT_THREADS"
		aidevops_log_line "[pulse-merge] pre-merge snapshot: PR #${pr_number} in ${repo_slug} has ${bot_count} unresolved review-bot thread(s) — merge blocked until resolved or classified (GH#27137)"
		return 1
	fi
	[[ "$total_count" -gt 0 ]] || return 0
	resolution_required=$(_pmrc_review_thread_resolution_required "$repo_slug" "$base_branch") || return 1
	if [[ "$resolution_required" == "$PMRC_BOOL_TRUE" ]]; then
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_REQUIRED_REVIEW_THREADS"
		aidevops_log_line "[pulse-merge] pre-merge snapshot: PR #${pr_number} in ${repo_slug} has ${total_count} unresolved review thread(s), and branch ${base_branch} requires thread resolution — merge blocked (GH#28130)"
		return 1
	fi
	return 0
}

_pmrc_is_explicit_advisory_failure() {
	local check_name="$1"
	local checks_json="$2"
	local companion=""
	case "$check_name" in
	"Qlty Smell Threshold") companion="Qlty Smell Regression" ;;
	*) return 1 ;;
	esac
	jq -e --arg companion "$companion" --arg completed "$PMRC_CHECK_COMPLETED" \
		--arg success "$PMRC_CHECK_SUCCESS" '[.[]? | select(.name == $companion and .status == $completed and .conclusion == $success)] | length > 0' \
		<<<"$checks_json" >/dev/null 2>&1
	return $?
}

_pmrc_actions_incident_blocks_rerun() {
	local helper="${AIDEVOPS_GH_STATUS_HELPER:-${_PULSE_MERGE_REQUIRED_CHECKS_DIR:-${HOME:+$HOME/.aidevops/agents/scripts}}/gh-status-helper.sh}"
	local status_rc=0
	[[ "${AIDEVOPS_SKIP_GITHUB_ACTIONS_STATUS:-0}" != "1" ]] || return 1
	[[ -x "$helper" ]] || return 1
	"$helper" check-actions --json >/dev/null 2>&1 || status_rc=$?
	[[ "$status_rc" -eq 1 ]]
	return $?
}

#######################################
# Request a bounded rerun for a GitHub Actions job whose failed log proves an
# infrastructure failure. The merge remains blocked until a later snapshot
# observes a successful replacement run.
#
# Args: $1=repo_slug, $2=pr_number, $3=check_name, $4=check_url
# Returns: 0=rerun requested or within cooldown, 1=invalid/unavailable
#######################################
_pmrc_rerun_infrastructure_check() {
	local repo_slug="$1"
	local pr_number="$2"
	local check_name="$3"
	local check_url="$4"
	local run_id="" cooldown_seconds="${PULSE_MERGE_INFRA_RERUN_COOLDOWN_SECONDS:-900}"
	local state_root="${AIDEVOPS_TEMP_DIR:-${HOME:+$HOME/.aidevops/.agent-workspace/tmp}}"
	local state_dir="${PULSE_MERGE_INFRA_RERUN_STATE_DIR:-${state_root:+$state_root/pulse-infra-check-reruns}}"
	local state_file="" now_epoch="${PULSE_MERGE_NOW_EPOCH:-$(date +%s)}" last_attempt="0"

	[[ -n "$repo_slug" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	[[ "$check_url" == "https://github.com/${repo_slug}/actions/runs/"*"/job/"* ]] || return 1
	run_id="${check_url#*/actions/runs/}"
	run_id="${run_id%%/*}"
	[[ "$run_id" =~ ^[0-9]+$ ]] || return 1
	[[ "$cooldown_seconds" =~ ^[0-9]+$ ]] || cooldown_seconds=900
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$state_dir" ]] || return 1

	if declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 &&
		! repo_allows_pulse_write_actions "$repo_slug"; then
		aidevops_log_line "[pulse-merge] infrastructure rerun deferred for PR #${pr_number} check '${check_name}' in ${repo_slug} — repository writes are disabled"
		return 1
	fi

	if _pmrc_actions_incident_blocks_rerun; then
		aidevops_log_line "[pulse-merge] infrastructure rerun deferred for PR #${pr_number} check '${check_name}' in ${repo_slug} — GitHub Status reports an active Actions incident; retry amplification suppressed"
		return 0
	fi

	mkdir -p "$state_dir" 2>/dev/null || return 1
	state_file="${state_dir}/${repo_slug//\//-}-${run_id}.last-attempt"
	if [[ -f "$state_file" ]]; then
		IFS= read -r last_attempt <"$state_file" || last_attempt="0"
	fi
	[[ "$last_attempt" =~ ^[0-9]+$ ]] || last_attempt=0
	if [[ $((now_epoch - last_attempt)) -lt "$cooldown_seconds" ]]; then
		aidevops_log_line "[pulse-merge] infrastructure rerun cooldown active for PR #${pr_number} check '${check_name}' in ${repo_slug} (run=${run_id}, cooldown=${cooldown_seconds}s) — merge remains blocked"
		return 0
	fi

	printf '%s\n' "$now_epoch" >"$state_file" || return 1
	#aidevops:trust-boundary — the run ID comes from the current-head check-run
	# URL returned by GitHub, and the repository already passed pulse write policy.
	if gh run rerun "$run_id" --repo "$repo_slug" --failed >/dev/null 2>&1; then
		aidevops_log_line "[pulse-merge] requested infrastructure rerun for PR #${pr_number} check '${check_name}' in ${repo_slug} (run=${run_id}) — merge remains blocked pending fresh success (GH#27825)"
		return 0
	fi
	aidevops_log_line "[pulse-merge] infrastructure rerun request failed for PR #${pr_number} check '${check_name}' in ${repo_slug} (run=${run_id}); cooldown recorded — merge remains blocked (GH#27825)"
	return 0
}

_pmrc_configured_advisory_contexts_json() {
	local repo_slug="$1"
	local repos_json="${AIDEVOPS_REPOS_JSON:-$HOME/.config/aidevops/repos.json}"
	local contexts="[]"

	if [[ ! -f "$repos_json" ]]; then
		printf '[]\n'
		return 0
	fi
	contexts=$(jq -c --arg slug "$repo_slug" --arg array_type "$PMRC_JSON_ARRAY" '
		((first(.initialized_repos[]? | select(((.slug // "") | ascii_downcase) == ($slug | ascii_downcase))) // {})
		| .review_gate.advisory_check_contexts // []) as $contexts
		| if ($contexts | type) == $array_type and all($contexts[]; type == "string" and length > 0)
			then ($contexts | unique)
			else error("invalid review_gate.advisory_check_contexts") end
	' "$repos_json" 2>/dev/null) || return 1
	printf '%s\n' "$contexts"
	return 0
}

_pmrc_review_evidence_permits_advisory() {
	local evidence_json="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local head_sha="$4"

	jq -e --arg repo "$repo_slug" --arg pr "$pr_number" --arg head "$head_sha" '
		"trusted" as $trusted
		| .schema == "aidevops.review-gate-evidence/v1"
		and .repo == $repo and (.pr | tostring) == $pr and .head_sha == $head
		and .permitted == true and .state == "pass" and .merge_gate == "clear"
		and (
			.status == "PASS"
			or (.status == "PASS_ADVISORY" and .author.class == $trusted)
			or (.status == "SKIP" and .author.class == $trusted)
			or (.status == "PASS_RATE_LIMITED" and .author.class == $trusted)
			or (.status == "SKIP_TRUSTED_DEPENDABOT" and .author.class == "trusted-bot")
		)
	' <<<"$evidence_json" >/dev/null 2>&1
	return $?
}

_pmrc_is_configured_advisory_failure() {
	local check_name="$1"
	local configured_contexts_json="$2"
	local evidence_json="$3"
	local repo_slug="$4"
	local pr_number="$5"
	local head_sha="$6"

	jq -e --arg name "$check_name" 'index($name) != null' <<<"$configured_contexts_json" >/dev/null 2>&1 || return 1
	_pmrc_review_evidence_permits_advisory "$evidence_json" "$repo_slug" "$pr_number" "$head_sha"
	return $?
}

_pmrc_snapshot_checks_acceptable() {
	local repo_slug="$1"
	local pr_number="$2"
	local checks_json="$3"
	local required_contexts="$4"
	local evidence_json="${5:-}"
	local head_sha="${6:-}"
	local required_json="" configured_contexts_json="" rows="" name="" family="" status="" conclusion="" required="" members="" link=""
	local blocking_names=""
	local blockers=0 pending=0 advisory=0
	_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON="[]"

	required_json=$(printf '%s' "$required_contexts" | jq -Rsc '[split("\n")[] | select(length > 0)]') || return 1
	configured_contexts_json=$(_pmrc_configured_advisory_contexts_json "$repo_slug") || {
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
		_pmrc_snapshot_log_failure "$repo_slug" "${PMRC_SUBJECT_PR_PREFIX}${pr_number}" \
			"configured advisory-context lookup"
		return 1
	}
	rows=$(jq -r --argjson required "$required_json" --arg failure "$PMRC_CHECK_FAILURE" '.[] | . as $check | ($check.members // [$check]) as $members | [
		$check.name,
		($check.family // $check.name),
		$check.status,
		$check.conclusion,
		((($required | index($check.name)) != null) or any($members[]; .name as $member_name | ($required | index($member_name)) != null)),
		($members | map("\(.name)@\(.source)") | join(",")),
		($check.link // ([$members[] | select(.conclusion == $failure and (.link // "") != "") | .link] | last) // "")
	] | @tsv' <<<"$checks_json" 2>/dev/null) || return 1
	while IFS=$'\t' read -r name family status conclusion required members link; do
		[[ -n "$name" ]] || continue
		if [[ "$family" == "$PMRC_MAINTAINER_GATE" && "$conclusion" == "$PMRC_CHECK_FAILURE" ]]; then
			if declare -F _ci_check_url_has_infra_failure_log >/dev/null 2>&1 &&
				_ci_check_url_has_infra_failure_log "$repo_slug" "$link"; then
				_pmrc_rerun_infrastructure_check "$repo_slug" "$pr_number" "$name" "$link" || true
				echo "[pulse-merge] pre-merge snapshot: maintainer-gate family has a proven infrastructure failure for PR #${pr_number} in ${repo_slug} — code repair suppressed; merge blocked pending rerun" >>"$LOGFILE"
				blockers=$((blockers + 1))
				continue
			fi
			echo "[pulse-merge] pre-merge snapshot: maintainer-gate family is terminal-failure for PR #${pr_number} in ${repo_slug}; aliases=${members}, required=${required}, active_alias_present=$([[ "$status" != "$PMRC_CHECK_COMPLETED" ]] && printf true || printf false) — merge blocked" >>"$LOGFILE"
			blockers=$((blockers + 1))
			continue
		fi
		if [[ "$status" != "$PMRC_CHECK_COMPLETED" || -z "$conclusion" ]]; then
			pending=$((pending + 1))
			continue
		fi
		case "$conclusion" in
		success | neutral | skipped) continue ;;
		esac
		if [[ "$family" == "$PMRC_MAINTAINER_GATE" ]]; then
			echo "[pulse-merge] pre-merge snapshot: maintainer-gate family is terminal-${conclusion} for PR #${pr_number} in ${repo_slug}; aliases=${members}, required=${required} — merge blocked" >>"$LOGFILE"
			blockers=$((blockers + 1))
		elif [[ "$required" == "$PMRC_BOOL_TRUE" ]] &&
			declare -F _ci_check_url_has_infra_failure_log >/dev/null 2>&1 &&
			_ci_check_url_has_infra_failure_log "$repo_slug" "$link"; then
			_pmrc_rerun_infrastructure_check "$repo_slug" "$pr_number" "$name" "$link" || true
			echo "[pulse-merge] pre-merge snapshot: required check '${name}' has a proven infrastructure failure for PR #${pr_number} in ${repo_slug} — code repair suppressed; merge blocked pending rerun" >>"$LOGFILE"
			blockers=$((blockers + 1))
		elif [[ "$required" == "$PMRC_BOOL_TRUE" ]]; then
			echo "[pulse-merge] pre-merge snapshot: required check '${name}' is terminal-${conclusion} for PR #${pr_number} in ${repo_slug} (GH#27137)" >>"$LOGFILE"
			blocking_names="${blocking_names}${name}"$'\n'
			blockers=$((blockers + 1))
		elif declare -F _ci_check_url_has_infra_failure_log >/dev/null 2>&1 &&
			_ci_check_url_has_infra_failure_log "$repo_slug" "$link"; then
			echo "[pulse-merge] pre-merge snapshot: IGNORED non-required infrastructure failure '${name}' for PR #${pr_number} in ${repo_slug} after failed-log classification (GH#27600)" >>"$LOGFILE"
			advisory=$((advisory + 1))
		elif _pmrc_is_explicit_advisory_failure "$name" "$checks_json"; then
			echo "[pulse-merge] pre-merge snapshot: IGNORED non-required baseline advisory failure '${name}' because its regression companion passed for PR #${pr_number} in ${repo_slug} (GH#27137)" >>"$LOGFILE"
			advisory=$((advisory + 1))
		elif _pmrc_is_configured_advisory_failure "$name" "$configured_contexts_json" "$evidence_json" "$repo_slug" "$pr_number" "$head_sha"; then
			echo "[pulse-merge] pre-merge snapshot: IGNORED configured non-required review-provider failure '${name}' with typed current-head review evidence for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
			advisory=$((advisory + 1))
		else
			echo "[pulse-merge] pre-merge snapshot: unclassified non-required check '${name}' is terminal-${conclusion} for PR #${pr_number} in ${repo_slug} — merge blocked (GH#27137)" >>"$LOGFILE"
			blocking_names="${blocking_names}${name}"$'\n'
			blockers=$((blockers + 1))
		fi
	done <<<"$rows"
	if [[ -n "$blocking_names" ]]; then
		_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON=$(jq -c --arg names "$blocking_names" '
			($names | split("\n") | map(select(length > 0))) as $blocking_names
			| [.[]? | select(.name as $name | $blocking_names | index($name))
				| {name, bucket: "fail", state: (.conclusion | ascii_upcase), conclusion, link}]
		' <<<"$checks_json" 2>/dev/null) || _PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON="[]"
	fi
	if [[ "$pending" -gt 0 || "$blockers" -gt 0 ]]; then
		if [[ "$blockers" -gt 0 ]]; then
			_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_CHECKS_FAILED"
		else
			_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_CHECKS_ACTIVE"
		fi
		echo "[pulse-merge] pre-merge snapshot: PR #${pr_number} in ${repo_slug} not ready (active=${pending}, blocking_failures=${blockers}, advisory_failures=${advisory}) (GH#27137)" >>"$LOGFILE"
		return 1
	fi
	echo "[pulse-merge] pre-merge snapshot: terminal check set accepted for PR #${pr_number} in ${repo_slug} (advisory_failures=${advisory}) (GH#27137)" >>"$LOGFILE"
	return 0
}

_pmrc_snapshot_review_gate_fresh() {
	local repo_slug="$1"
	local pr_number="$2"
	local checks_json="$3"
	local activity_json="$4"
	local live_gate_evidence="${5:-}"
	local gate_at="" activity_at="" evidence_at="" gate_epoch="" activity_epoch="" evidence_epoch=""

	gate_at=$(jq -r --arg completed "$PMRC_CHECK_COMPLETED" --arg success "$PMRC_CHECK_SUCCESS" '[.[]? | select((.name == "review-bot-gate" or .name == "gate / review-bot-gate") and .status == $completed and .conclusion == $success) | .observed_at | select(. != "")] | max // ""' <<<"$checks_json") || return 1
	activity_at=$(jq -r '.latest_at // ""' <<<"$activity_json") || return 1
	if [[ -n "$activity_at" ]]; then
		activity_epoch=$(_pmrc_iso_to_epoch "$activity_at") || return 1
	fi
	if [[ -n "$live_gate_evidence" ]]; then
		evidence_at=$(jq -r '.observed_at // ""' <<<"$live_gate_evidence") || return 1
		if [[ -n "$evidence_at" ]]; then
			evidence_epoch=$(_pmrc_iso_to_epoch "$evidence_at") || return 1
		fi
	fi
	if [[ -z "$gate_at" ]]; then
		#aidevops:trust-boundary — the live helper ran for this exact PR/head, and
		# the caller immediately revalidates that head before reaching this check.
		# Its caller-observed timestamp must also cover the latest bot activity so
		# activity racing after the live helper remains fail-closed.
		if [[ "$evidence_epoch" =~ ^[0-9]+$ ]] &&
			{ [[ -z "$activity_epoch" ]] || [[ "$evidence_epoch" -ge "$activity_epoch" ]]; }; then
			echo "[pulse-merge] pre-merge snapshot: accepted live review-bot gate bound to the current head for PR #${pr_number} in ${repo_slug}; no status context is installed (GH#27483)" >>"$LOGFILE"
			return 0
		fi
		echo "[pulse-merge] pre-merge snapshot: no successful review-bot gate is bound to the current head for PR #${pr_number} in ${repo_slug} (GH#27137)" >>"$LOGFILE"
		return 1
	fi
	[[ -z "$activity_at" ]] && return 0
	gate_epoch=$(_pmrc_iso_to_epoch "$gate_at") || return 1
	if [[ "$activity_epoch" -gt "$gate_epoch" ]]; then
		#aidevops:trust-boundary — permitted live evidence is bound to the exact
		# current head. Accept it only when it was observed after the latest bot
		# activity; otherwise retain the stale-status fail-closed decision.
		if [[ "$evidence_epoch" =~ ^[0-9]+$ && "$evidence_epoch" -ge "$activity_epoch" ]]; then
			echo "[pulse-merge] pre-merge snapshot: accepted current-head live review evidence observed after the stale status context for PR #${pr_number} in ${repo_slug} (status_gate=${gate_at}, latest_review_activity=${activity_at}, live_evidence=${evidence_at})" >>"$LOGFILE"
			return 0
		fi
		echo "[pulse-merge] pre-merge snapshot: review-bot gate is stale for PR #${pr_number} in ${repo_slug} (gate=${gate_at}, latest_review_activity=${activity_at}) (GH#27137)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

_pmrc_snapshot_quiet_period_passes() {
	local repo_slug="$1"
	local pr_number="$2"
	local checks_json="$3"
	local activity_json="$4"
	local quiet_seconds="${PULSE_MERGE_QUIET_PERIOD_SECONDS:-30}"
	local now_epoch="${PULSE_MERGE_NOW_EPOCH:-$(date +%s)}" latest_at="" latest_epoch="" age=""

	[[ "$quiet_seconds" =~ ^[0-9]+$ ]] || quiet_seconds=30
	latest_at=$(jq -nr --argjson checks "$checks_json" --argjson activity "$activity_json" '[
		($checks[]?.observed_at // ""), ($activity.latest_at // "")
	] | map(select(. != "")) | max // ""') || return 1
	[[ -n "$latest_at" ]] || return 0
	latest_epoch=$(_pmrc_iso_to_epoch "$latest_at") || return 1
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || return 1
	age=$((now_epoch - latest_epoch))
	if [[ "$age" -lt "$quiet_seconds" ]]; then
		echo "[pulse-merge] pre-merge snapshot: PR #${pr_number} in ${repo_slug} has been quiet for ${age}s; ${quiet_seconds}s required (GH#27137)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

_pulse_merge_preflight_snapshot_gate() {
	local repo_slug="$1"
	local pr_number="$2"
	local expected_head_sha="$3"
	local live_gate_evidence="${_PULSE_REVIEW_GATE_EVIDENCE:-}"
	local pr_json="" pr_coordinates="" current_head_sha="" base_branch="" required_contexts="" checks_json="" activity_json=""
	_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON="[]"
	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND=""

	pr_json=$(_pmrc_gh_read gh api "repos/${repo_slug}/pulls/${pr_number}" 2>/dev/null) || {
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
		_pmrc_snapshot_log_failure "$repo_slug" "${PMRC_SUBJECT_PR_PREFIX}${pr_number}" "pull-request fetch"
		return 1
	}
	if [[ -z "$pr_json" ]]; then
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
		_pmrc_snapshot_log_failure "$repo_slug" "${PMRC_SUBJECT_PR_PREFIX}${pr_number}" "pull-request parse"
		return 1
	fi
	pr_coordinates=$(jq -r '[(.head.sha // ""), (.base.ref // "")] | join("\u001f")' <<<"$pr_json") || {
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
		_pmrc_snapshot_log_failure "$repo_slug" "${PMRC_SUBJECT_PR_PREFIX}${pr_number}" "pull-request parse"
		return 1
	}
	IFS=$'\x1f' read -r current_head_sha base_branch <<<"$pr_coordinates"
	if [[ -z "$current_head_sha" || "$current_head_sha" != "$expected_head_sha" ]]; then
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_HEAD_CHANGED"
		echo "[pulse-merge] pre-merge snapshot: head changed for PR #${pr_number} in ${repo_slug} (expected=${expected_head_sha:-unknown}, current=${current_head_sha:-unknown}) — prior gate state revoked (GH#27137)" >>"$LOGFILE"
		return 1
	fi
	required_contexts=$(_required_contexts_for_default_branch "$repo_slug") || {
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
		_pmrc_snapshot_log_failure "$repo_slug" "${PMRC_SUBJECT_PR_PREFIX}${pr_number}" "required-context lookup"
		return 1
	}
	checks_json=$(_pmrc_snapshot_checks_json "$repo_slug" "$current_head_sha") || {
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
		return 1
	}
	if declare -F _pmp_record_same_pass_check_evidence >/dev/null 2>&1; then
		_pmp_record_same_pass_check_evidence "$repo_slug" "$current_head_sha" "$checks_json" || true
	fi
	activity_json=$(_pmrc_snapshot_bot_activity_json "$repo_slug" "$pr_number") || {
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
		return 1
	}
	_pmrc_review_evidence_permits_advisory "$live_gate_evidence" "$repo_slug" "$pr_number" "$current_head_sha" || live_gate_evidence=""
	if ! _pmrc_snapshot_review_gate_fresh "$repo_slug" "$pr_number" "$checks_json" "$activity_json" "$live_gate_evidence"; then
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_REVIEW_GATE"
		return 1
	fi
	if ! _pmrc_snapshot_review_threads_clear "$repo_slug" "$pr_number" "$base_branch"; then
		[[ -n "$_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND" ]] ||
			_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
		return 1
	fi
	if ! _pmrc_snapshot_checks_acceptable \
		"$repo_slug" "$pr_number" "$checks_json" "$required_contexts" \
		"$live_gate_evidence" "$current_head_sha"; then
		[[ -n "$_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND" ]] ||
			_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_CHECKS_FAILED"
		_pmrc_record_preflight_check_mismatch
		return 1
	fi
	if ! _pmrc_snapshot_quiet_period_passes "$repo_slug" "$pr_number" "$checks_json" "$activity_json"; then
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_QUIET_PERIOD"
		return 1
	fi
	echo "[pulse-merge] pre-merge snapshot: current head ${current_head_sha:0:12}, fresh review gate, merge-policy-compatible review threads, terminal checks, and quiet period verified for PR #${pr_number} in ${repo_slug} (GH#27137)" >>"$LOGFILE"
	return 0
}

#######################################
# Normalize the exact required-check read used by the PR-level fallback.
# Args: $1=repo_slug, $2=pr_number
# Stdout: checks JSON
# Returns: 0=usable JSON or canonical no-required result, 2=API/parse error
#######################################
_pmrc_exact_required_checks_json() {
	local repo_slug="$1"
	local pr_number="$2"
	local checks_json="" checks_exit=0
	local checks_stderr="" checks_stderr_file=""

	checks_stderr_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-pulse-required-checks.XXXXXX") || return 2
	checks_json=$(gh_pr_checks_exact_json "$repo_slug" "$pr_number" required \
		2>"$checks_stderr_file") || checks_exit=$?
	checks_stderr=$(<"$checks_stderr_file")
	rm -f "$checks_stderr_file"
	if [[ "$checks_exit" -eq 1 && -z "$checks_json" && "$checks_stderr" =~ ^no\ required\ checks\ reported\ on\ the\ \'[^\']+\'\ branch$ ]]; then
		printf '[]\n'
		return 0
	fi
	if [[ "$checks_exit" -ne 0 && -z "$checks_json" ]]; then
		return 2
	fi
	[[ -z "$checks_stderr" ]] || return 2
	if [[ -z "$checks_json" || "$checks_json" == "null" || "$checks_json" == "[]" ]]; then
		if [[ "$checks_exit" -ne 0 ]]; then
			return 2
		fi
		printf '[]\n'
		return 0
	fi
	printf '%s\n' "$checks_json"
	return 0
}

#######################################
# Fallback required-check verification for repositories where the classic branch
# protection endpoint and repository-rulesets endpoint expose no contexts, but
# GitHub still reports PR-level required checks (for example org-level rulesets).
#
# Args: $1=repo_slug, $2=pr_number
# Returns: 0=all reported required checks passing or none reported,
#          1=at least one reported required check is not passing,
#          2=API/parse error
#######################################
_check_required_pr_checks_passing_fallback() {
	local repo_slug="$1"
	local pr_number="$2"

	local checks_json=""
	checks_json=$(_pmrc_exact_required_checks_json "$repo_slug" "$pr_number") || return 2
	if [[ "$checks_json" == "[]" ]]; then
		printf '[]\n'
		return 0
	fi

	local nonpassing_count="" _pc_exit=0
	nonpassing_count=$(printf '%s' "$checks_json" |
		jq '[.[]? | select((.bucket // "") != "pass")] | length' 2>/dev/null)
	_pc_exit=$?
	if [[ $_pc_exit -ne 0 || -z "$nonpassing_count" ]]; then
		return 2
	fi

	if [[ "$nonpassing_count" -gt 0 ]]; then
		local stale_gate_pending_count="" _sg_exit=0
		stale_gate_pending_count=$(printf '%s' "$checks_json" | jq --arg stable "$PMRC_MAINTAINER_GATE" --arg legacy "$PMRC_MAINTAINER_GATE_DISPLAY" '
			"pass" as $pass | "PENDING" as $pending |
			[.[]?
			| (.name // "") as $name
			| select((.bucket // "") != $pass)
			| select(((.state // "") | ascii_upcase) == $pending)
			| select($name == $stable or $name == $legacy)
		] | length' 2>/dev/null)
		_sg_exit=$?
		if [[ $_sg_exit -ne 0 || -z "$stale_gate_pending_count" ]]; then
			return 2
		fi

		if [[ "$stale_gate_pending_count" -eq "$nonpassing_count" ]]; then
			local pr_sha="" rollup_json="" gate_pass_count="" _gp_exit=0
			if declare -F gh_pr_view >/dev/null 2>&1; then
				pr_sha=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
					--json headRefOid --jq '.headRefOid // ""' 2>/dev/null) || pr_sha=""
			else
				pr_sha=$(_pmrc_gh_read gh pr view "$pr_number" --repo "$repo_slug" \
					--json headRefOid --jq '.headRefOid // ""' 2>/dev/null) || pr_sha=""
			fi
			if [[ -n "$pr_sha" ]]; then
				local status_json="" pending_gate_status_count="" _ps_exit=0
				status_json=$(_pmrc_gh_read gh api "repos/${repo_slug}/commits/${pr_sha}/status" 2>/dev/null) || status_json=""
				if [[ -n "$status_json" && "$status_json" != null ]]; then
					pending_gate_status_count=$(jq --arg stable "$PMRC_MAINTAINER_GATE" --arg legacy "$PMRC_MAINTAINER_GATE_DISPLAY" '
						[.statuses[]?
						| (.context // "") as $name
						| select(($name == $stable or $name == $legacy)
							and (((.state // "") | ascii_downcase) == "pending"))
						] | length' <<<"$status_json" 2>/dev/null)
					_ps_exit=$?
					if [[ $_ps_exit -ne 0 || -z "$pending_gate_status_count" ]]; then
						return 2
					fi
					if [[ "$pending_gate_status_count" -gt 0 ]]; then
						return 1
					fi
				fi
			fi
			if [[ -n "$pr_sha" ]] && declare -F gh_pr_check_runs_rest >/dev/null 2>&1; then
				rollup_json=$(gh_pr_check_runs_rest "$repo_slug" "$pr_sha" 2>/dev/null) || rollup_json=""
				if [[ -n "$rollup_json" && "$rollup_json" != null ]]; then
					gate_pass_count=$(jq '
						"gate / Maintainer Review & Assignee Gate" as $gate |
						"success" as $ok | "neutral" as $neutral |
						"skipped" as $skipped |
						[.[]?
						| select((.name // "") == $gate)
						| ((.conclusion // "") | ascii_downcase) as $conclusion
						| select($conclusion == $ok or $conclusion == $neutral
							or $conclusion == $skipped)
					] | length' <<<"$rollup_json" 2>/dev/null)
					_gp_exit=$?
					if [[ $_gp_exit -eq 0 && "$gate_pass_count" =~ ^[0-9]+$ &&
						"$gate_pass_count" -gt 0 ]]; then
						return 0
					fi
				fi
			fi
		fi
		return 1
	fi
	return 0
}

#######################################
# Resolve the maximum required approval count from active rulesets matching
# the repository default branch. This is separate from required status checks:
# GitHub stores ruleset approval requirements under pull_request rules, not as
# CI contexts, so an empty status context list is not enough to allow a merge.
#
# Args: $1=repo_slug, $2=default_branch, $3=optional pre-fetched rulesets JSON
# Stdout: integer maximum required_approving_review_count (0 when none)
# Returns: 0=requirement resolved, 1=ruleset API/parse error
#######################################
_ruleset_required_review_count_for_default_branch() {
	local repo_slug="$1"
	local default_branch="$2"
	local rulesets_json="${3:-}"

	if [[ -z "$rulesets_json" ]]; then
		rulesets_json=$(_pmrc_gh_read gh api "repos/${repo_slug}/rulesets" 2>/dev/null) || {
			aidevops_log_line "[pulse-merge] _ruleset_required_review_count_for_default_branch: rulesets list failed for ${repo_slug} — caller will fail closed (GH#24577)"
			return 1
		}
	fi
	[[ -n "$rulesets_json" && "$rulesets_json" != "[]" && "$rulesets_json" != null ]] || {
		printf '0'
		return 0
	}

	local active_ids=""
	active_ids=$(printf '%s' "$rulesets_json" | aidevops_run_with_log_stderr jq -r '.[]? | select(.enforcement == "active") | .id // empty') || {
		aidevops_log_line "[pulse-merge] _ruleset_required_review_count_for_default_branch: rulesets list parse failed for ${repo_slug} — caller will fail closed (GH#24577)"
		return 1
	}
	[[ -n "$active_ids" ]] || {
		printf '0'
		return 0
	}

	local max_required=0
	local id="" detail="" include_patterns="" exclude_patterns="" pattern=""
	local matches_default=0 excluded_default=0 approval_count=""
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		detail=$(_pmrc_gh_read gh api "repos/${repo_slug}/rulesets/${id}" 2>/dev/null) || {
			aidevops_log_line "[pulse-merge] _ruleset_required_review_count_for_default_branch: ruleset detail ${id} failed for ${repo_slug} — caller will fail closed (GH#24577)"
			return 1
		}
		include_patterns=$(printf '%s' "$detail" | aidevops_run_with_log_stderr jq -r '.conditions?.ref_name?.include? // [] | .[]') || return 1
		exclude_patterns=$(printf '%s' "$detail" | aidevops_run_with_log_stderr jq -r '.conditions?.ref_name?.exclude? // [] | .[]') || return 1

		matches_default=0
		while IFS= read -r pattern; do
			[[ -n "$pattern" ]] || continue
			_ruleset_ref_matches_default_branch "$pattern" "$default_branch" || continue
			matches_default=1
			break
		done <<<"$include_patterns"
		[[ "$matches_default" -eq 1 ]] || continue

		excluded_default=0
		while IFS= read -r pattern; do
			[[ -n "$pattern" ]] || continue
			_ruleset_ref_matches_default_branch "$pattern" "$default_branch" || continue
			excluded_default=1
			break
		done <<<"$exclude_patterns"
		[[ "$excluded_default" -eq 0 ]] || continue

		approval_count=$(printf '%s' "$detail" | aidevops_run_with_log_stderr jq -r '[.rules[]? | select(.type == "pull_request") | (.parameters?.required_approving_review_count? // 0)] | max // 0') || {
			aidevops_log_line "[pulse-merge] _ruleset_required_review_count_for_default_branch: pull-request rule parse failed for ruleset ${id} in ${repo_slug} — caller will fail closed (GH#24577)"
			return 1
		}
		[[ "$approval_count" =~ ^[0-9]+$ ]] || approval_count=0
		[[ "$approval_count" -gt "$max_required" ]] && max_required="$approval_count"
	done <<<"$active_ids"

	printf '%s' "$max_required"
	return 0
}

#######################################
# Verify active ruleset pull_request approval requirements for one PR.
#
# Args: $1=repo_slug, $2=pr_number, $3=pr_author
# Returns: 0=passes/no ruleset approval requirement, 1=missing/unverifiable
#######################################
_check_ruleset_required_reviews_passing() {
	local repo_slug="$1"
	local pr_number="$2"
	local pr_author="$3"

	local default_branch="" required_count=""
	default_branch=$(_pmrc_gh_read gh api "repos/${repo_slug}" --jq '.default_branch' 2>/dev/null) || default_branch=""
	if [[ -z "$default_branch" ]]; then
		echo "[pulse-merge] _check_ruleset_required_reviews_passing: failed to resolve default branch for ${repo_slug} — failing closed (GH#24577)" >>"$LOGFILE"
		return 1
	fi
	required_count=$(_ruleset_required_review_count_for_default_branch "$repo_slug" "$default_branch") || return 1
	[[ "$required_count" =~ ^[0-9]+$ ]] || required_count=0
	[[ "$required_count" -eq 0 ]] && return 0

	local reviews_pages="" approved_count="" empty_string=""
	reviews_pages=$(_pmrc_gh_read gh api "repos/${repo_slug}/pulls/${pr_number}/reviews?per_page=100" --paginate --slurp 2>/dev/null) || reviews_pages=""
	if [[ -z "$reviews_pages" || "$reviews_pages" == null ]]; then
		echo "[pulse-merge] _check_ruleset_required_reviews_passing: review fetch failed for PR #${pr_number} in ${repo_slug} with ruleset requiring ${required_count} approval(s) — failing closed (GH#24577)" >>"$LOGFILE"
		return 1
	fi
	approved_count=$(jq -er --arg author "$pr_author" --arg empty "$empty_string" \
		--arg array_type "$PMRC_JSON_ARRAY" --arg object_type "$PMRC_JSON_OBJECT" '
		if type != $array_type or any(.[]; type != $array_type) or any(.[][]?; type != $object_type) then
			error("invalid paginated reviews response")
		else
			[.[][]? | {
				login: (.user.login // $empty),
				state: (.state // $empty),
				submitted_at: (.submitted_at // $empty),
				id: (.id // 0)
			} | select(.login != $empty)]
			| group_by(.login)
			| map(max_by([.submitted_at, .id]))
			| map(select(.login != $author))
			| map(select((.state | ascii_upcase) == "APPROVED"))
			| length
		end
	' <<<"$reviews_pages" 2>/dev/null) || approved_count=""
	if [[ ! "$approved_count" =~ ^[0-9]+$ ]]; then
		echo "[pulse-merge] _check_ruleset_required_reviews_passing: review parse failed for PR #${pr_number} in ${repo_slug} — failing closed (GH#24577)" >>"$LOGFILE"
		return 1
	fi
	if [[ "$approved_count" -lt "$required_count" ]]; then
		echo "[pulse-merge] _check_ruleset_required_reviews_passing: PR #${pr_number} in ${repo_slug} has ${approved_count}/${required_count} ruleset-required approval(s) — deferring merge (GH#24577)" >>"$LOGFILE"
		return 1
	fi
	echo "[pulse-merge] _check_ruleset_required_reviews_passing: PR #${pr_number} in ${repo_slug} satisfies ${approved_count}/${required_count} ruleset-required approval(s) (GH#24577)" >>"$LOGFILE"
	return 0
}

#######################################
# Return whether any branch-protection-required check on a PR is in a terminal
# failed state. Pending states are explicitly non-terminal: queued, pending,
# in_progress, waiting, skipped-by-dependency, expected, absent-from-rollup,
# and null conclusions must not trigger close/requeue/repair routing.
#
# Args: $1=repo_slug, $2=pr_number, $3=expected_head_sha (optional)
# Returns: 0=terminal failure found, 1=no terminal failures, 2=API/parse error
#######################################
_check_required_checks_has_terminal_failure() {
	local repo_slug="$1"
	local pr_number="$2"
	local expected_head_sha="${3:-}"

	local required_contexts=""
	required_contexts=$(_required_contexts_for_default_branch "$repo_slug") || return 2
	if [[ -z "$required_contexts" ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: no required contexts for ${repo_slug} — allowing (t3567)" >>"$LOGFILE"
		return 1
	fi

	local pr_sha="$expected_head_sha"
	if [[ -z "$pr_sha" ]]; then
		pr_sha=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json headRefOid --jq '.headRefOid // ""') || true
	fi
	if [[ -z "$pr_sha" ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: headRefOid fetch failed for PR #${pr_number} in ${repo_slug} — failing closed (t3567)" >>"$LOGFILE"
		return 2
	fi

	local rollup_json=""
	rollup_json=$(gh_pr_check_runs_rest "$repo_slug" "$pr_sha" 2>/dev/null) || rollup_json=""
	if [[ -z "$rollup_json" || "$rollup_json" == null ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: REST check-runs fetch failed for PR #${pr_number} in ${repo_slug} — failing closed (t3567)" >>"$LOGFILE"
		return 2
	fi

	local req_json
	req_json=$(printf '%s' "$required_contexts" |
		jq -Rsc '[split("\n")[] | select(length > 0)]' 2>/dev/null) || req_json="[]"

	local failing_count="" _fc_exit=0
	failing_count=$(jq -n \
		--argjson req "$req_json" \
		--argjson checks "$rollup_json" \
		'$req | map(
			. as $ctx |
			($checks | map(select((.name // "") == $ctx)) | last) as $c |
			if $c == null then false
			elif (($c.conclusion // "" | ascii_downcase)
				| . == "failure" or . == "cancelled" or . == "timed_out") then true
			else false
			end
		) | map(select(.)) | length' 2>/dev/null)
	_fc_exit=$?

	if [[ $_fc_exit -ne 0 || -z "$failing_count" ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: jq evaluation failed for PR #${pr_number} in ${repo_slug} — failing closed (t3567)" >>"$LOGFILE"
		return 2
	fi

	if [[ "$failing_count" -gt 0 ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: ${failing_count} terminal failed required context(s) for PR #${pr_number} in ${repo_slug} (t3567)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-merge] _check_required_checks_has_terminal_failure: no terminal failed required contexts for PR #${pr_number} in ${repo_slug} (t3567)" >>"$LOGFILE"
	return 1
}

#######################################
# Return whether any branch-protection-required check on the current PR head is
# queued, pending, in progress, waiting, or absent from the current head rollup.
# This is the pre-update guard for branch refresh paths: mutating a PR branch
# while required checks are still active restarts CI and wastes runner time.
#
# Args: $1=repo_slug, $2=pr_number, $3=expected_head_sha (optional)
# Returns: 0=pending/in-progress required check found, 1=no active required
#          checks, 2=API/parse error
#######################################
_check_required_checks_have_pending_or_in_progress() {
	local repo_slug="$1"
	local pr_number="$2"
	local expected_head_sha="${3:-}"

	local required_contexts=""
	required_contexts=$(_required_contexts_for_default_branch "$repo_slug") || return 2
	if [[ -z "$required_contexts" ]]; then
		echo "[pulse-merge] _check_required_checks_have_pending_or_in_progress: no required contexts for ${repo_slug} — no active required checks (GH#26406)" >>"$LOGFILE"
		return 1
	fi

	local pr_sha="$expected_head_sha"
	if [[ -z "$pr_sha" ]]; then
		pr_sha=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json headRefOid --jq '.headRefOid // ""') || true
	fi
	if [[ -z "$pr_sha" ]]; then
		echo "[pulse-merge] _check_required_checks_have_pending_or_in_progress: headRefOid fetch failed for PR #${pr_number} in ${repo_slug} — failing open for branch-update caller (GH#26406)" >>"$LOGFILE"
		return 2
	fi

	local rollup_json=""
	rollup_json=$(gh_pr_check_runs_rest "$repo_slug" "$pr_sha" 2>/dev/null) || rollup_json=""
	if [[ -z "$rollup_json" || "$rollup_json" == null ]]; then
		echo "[pulse-merge] _check_required_checks_have_pending_or_in_progress: REST check-runs fetch failed for PR #${pr_number} in ${repo_slug} — failing open for branch-update caller (GH#26406)" >>"$LOGFILE"
		return 2
	fi

	local req_json
	req_json=$(printf '%s' "$required_contexts" |
		jq -Rsc '[split("\n")[] | select(length > 0)]' 2>/dev/null) || req_json="[]"

	local pending_count="" _pc_exit=0
	pending_count=$(jq -n \
		--argjson req "$req_json" \
		--argjson checks "$rollup_json" \
		'$req | map(
			. as $ctx |
			($checks | map(select((.name // "") == $ctx)) | last) as $c |
			if $c == null then true
			elif (($c.conclusion // "") | length) == 0 then true
			elif (($c.status // "" | ascii_downcase)
				| . == "queued" or . == "pending" or . == "in_progress" or . == "waiting" or . == "requested") then true
			else false
			end
		) | map(select(.)) | length' 2>/dev/null)
	_pc_exit=$?

	if [[ $_pc_exit -ne 0 || -z "$pending_count" ]]; then
		echo "[pulse-merge] _check_required_checks_have_pending_or_in_progress: jq evaluation failed for PR #${pr_number} in ${repo_slug} — failing open for branch-update caller (GH#26406)" >>"$LOGFILE"
		return 2
	fi

	if [[ "$pending_count" -gt 0 ]]; then
		echo "[pulse-merge] _check_required_checks_have_pending_or_in_progress: ${pending_count} active required check(s) on current head for PR #${pr_number} in ${repo_slug} (GH#26406)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-merge] _check_required_checks_have_pending_or_in_progress: no active required checks on current head for PR #${pr_number} in ${repo_slug} (GH#26406)" >>"$LOGFILE"
	return 1
}
