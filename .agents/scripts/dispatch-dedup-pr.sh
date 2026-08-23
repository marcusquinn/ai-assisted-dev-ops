#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-dedup-pr.sh — PR evidence dedup checks for dispatch deduplication (GH#18916)
#
# Extracted from dispatch-dedup-helper.sh (GH#18916) to reduce that file below
# the 2000-line simplification gate.
#
# Sourced by dispatch-dedup-helper.sh. Do NOT invoke directly.
#
# Exports:
#   has_open_pr <issue> <slug> [issue-title]
#     Check whether an issue already has open or merged PR evidence.
#     Exit 0 = PR evidence exists (do NOT dispatch), exit 1 = no evidence.

_ddpr_gh_read() {
	local rc=0
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}

#######################################
# Read the current issue body from the canonical dispatch metadata bundle.
#
# Args: none
# Outputs: issue body when ISSUE_META_JSON is available
# Returns: 0 always
#######################################
_ddpr_issue_body_from_meta() {
	local issue_body=""
	if [[ -n "${ISSUE_META_JSON:-}" ]]; then
		issue_body=$(printf '%s' "$ISSUE_META_JSON" | jq -r '.body // empty' 2>/dev/null) || issue_body=""
	fi
	printf '%s' "$issue_body"
	return 0
}

#######################################
# Extract the related issue ref from the canonical consolidated-spec marker.
#
# Operational consolidation-task bodies inline instructions, parent threads,
# and historical references that may contain words such as "superseded" or
# "consolidated". Only a marker at the start of a line establishes the
# current issue's supersession relationship.
#
# Args: $1 = issue body
# Outputs: one issue number per line
# Returns: 0 always
#######################################
_ddpr_superseded_issue_refs() {
	local issue_body="$1"
	local line="" ref=""
	local marker_regex='^_Supersedes #([0-9]+) (—|-) this issue is the consolidated spec\._$'
	while IFS= read -r line; do
		line="${line%$'\r'}"
		if [[ "$line" =~ $marker_regex ]]; then
			ref="${BASH_REMATCH[1]:-}"
			printf '%s\n' "$ref"
		fi
	done <<<"$issue_body"
	return 0
}

#######################################
# Check whether dispatch metadata identifies an operational consolidation task.
#
# Args: none
# Returns: 0 for consolidation-task metadata, 1 otherwise
#######################################
_ddpr_is_consolidation_task() {
	[[ -n "${ISSUE_META_JSON:-}" ]] || return 1
	if printf '%s' "$ISSUE_META_JSON" | jq -e '
		[.labels[]? | if type == "object" then (.name // "") else . end]
		| any(. == "consolidation-task")
	' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

_DDPR_JSON_ARRAY_TYPE="array"
_DDPR_JSON_NUMBER_TYPE='number'

_ddpr_closing_keyword_pattern() {
	local issue_number="$1"
	printf '%s' "(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+([a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+)?#${issue_number}([^[:alnum:]_]|$)"
	return 0
}

#######################################
# Fetch open sibling PR candidates with response-owned GraphQL quota cost.
#
# Native `gh pr list` hides the multi-point GraphQL cost for this rich field
# shape. Keep the existing 20-result search bound, but request rateLimit.cost in
# the same response so exact-cost observations do not rely on cumulative deltas.
#
# Args: $1 = issue number, $2 = repo slug
# Outputs: gh-pr-list-compatible JSON array
# Returns: 0 for a complete response, 1 for API or validation failure
#######################################
_ddpr_graphql_open_siblings() {
	local issue_number="$1"
	local repo_slug="$2"
	local search_query="repo:${repo_slug} is:pr is:open #${issue_number}"
	local response="" pr_json=""

	# shellcheck disable=SC2016
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="dispatch-dedup-open-siblings-exact-cost" \
		_ddpr_gh_read gh api graphql -F queryString="$search_query" -f query='
		query($queryString: String!) {
			search(type: ISSUE, query: $queryString, first: 20) {
				nodes {
					__typename
					... on PullRequest {
						number title body isDraft reviewDecision
						mergeStateStatus mergeable changedFiles
						files(first: 100) {
							nodes { path }
							pageInfo { hasNextPage }
						}
						labels(first: 100) {
							nodes { name }
							pageInfo { hasNextPage }
						}
					}
				}
			}
			rateLimit { cost }
		}
	' 2>/dev/null) || return 1

	pr_json=$(printf '%s' "$response" | jq -ce \
		--arg array_type "$_DDPR_JSON_ARRAY_TYPE" --arg number_type "$_DDPR_JSON_NUMBER_TYPE" '
		select(((.errors // []) | type) == $array_type)
		| select(((.errors // []) | length) == 0)
		| select((.data.rateLimit.cost | type) == $number_type)
		| select(.data.rateLimit.cost > 0 and (.data.rateLimit.cost | floor) == .data.rateLimit.cost)
		| .data.search.nodes
		| select(type == $array_type)
		| select(all(.[];
			.__typename == "PullRequest" and
			(.number | type) == $number_type and
			(.isDraft | type) == "boolean" and
			((.files.nodes // []) | type) == $array_type and
			.files.pageInfo.hasNextPage == false and
			((.labels.nodes // []) | type) == $array_type and
			.labels.pageInfo.hasNextPage == false
		))
		| map({
			number,
			title,
			body,
			isDraft,
			reviewDecision,
			mergeStateStatus,
			mergeable,
			changedFiles,
			files: (.files.nodes // []),
			labels: (.labels.nodes // [])
		})
	' 2>/dev/null) || return 1
	printf '%s' "$pr_json"
	return 0
}

#######################################
# Fetch the ten newest open PR commit headlines with response-owned quota cost.
#
# Args: $1 = repo slug
# Outputs: gh-pr-list-compatible JSON array
# Returns: 0 for a complete response, 1 for API or validation failure
#######################################
_ddpr_graphql_open_commits() {
	local repo_slug="$1"
	local owner="${repo_slug%%/*}"
	local repo="${repo_slug#*/}"
	local response="" pr_json=""
	[[ -n "$owner" && -n "$repo" && "$repo_slug" == */* && "$repo" != */* ]] || return 1

	# shellcheck disable=SC2016
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="dispatch-dedup-open-commits-exact-cost" \
		_ddpr_gh_read gh api graphql -f owner="$owner" -f name="$repo" -f query='
		query($owner: String!, $name: String!) {
			repository(owner: $owner, name: $name) {
				pullRequests(
					first: 10,
					states: [OPEN],
					orderBy: {field: CREATED_AT, direction: DESC}
				) {
					nodes {
						number title isDraft
						commits(first: 100) {
							nodes { commit { messageHeadline } }
							pageInfo { hasNextPage }
						}
					}
				}
			}
			rateLimit { cost }
		}
	' 2>/dev/null) || return 1

	pr_json=$(printf '%s' "$response" | jq -ce \
		--arg array_type "$_DDPR_JSON_ARRAY_TYPE" --arg number_type "$_DDPR_JSON_NUMBER_TYPE" '
		select(((.errors // []) | type) == $array_type)
		| select(((.errors // []) | length) == 0)
		| select((.data.rateLimit.cost | type) == $number_type)
		| select(.data.rateLimit.cost > 0 and (.data.rateLimit.cost | floor) == .data.rateLimit.cost)
		| .data.repository.pullRequests.nodes
		| select(type == $array_type)
		| select(all(.[];
			(.number | type) == $number_type and
			(.isDraft | type) == "boolean" and
			(.commits.nodes | type) == $array_type and
			.commits.pageInfo.hasNextPage == false and
			all(.commits.nodes[]; (.commit.messageHeadline | type) == "string")
		))
		| map({
			number,
			title,
			isDraft,
			commits: [.commits.nodes[].commit | {messageHeadline}]
		})
	' 2>/dev/null) || return 1
	printf '%s' "$pr_json"
	return 0
}

#######################################
# has_open_pr Check 0: healthy open sibling PRs for this issue.
#
# Redispatch should not create another worker when an existing sibling PR for
# the same issue is already approved or mergeable. This catches PRs that are
# ready for the merge path but do not use a closing keyword in the body (for
# example parent/phase work using `For #NNN`). Drafts are durable checkpoints:
# worker drafts must be continued/escalated, while interactive/held/NMR drafts
# must remain untouched. Both kinds block competing ordinary dispatch.
#
# Args: $1 = issue number, $2 = repo slug
# Returns: exit 0 if a healthy sibling PR matches, exit 1 if none
#######################################
_has_open_pr_check_healthy_sibling() {
	local issue_number="$1"
	local repo_slug="$2"

	local pr_json match_pr draft_pr draft_pr_number draft_pr_kind
	pr_json=$(_ddpr_graphql_open_siblings "$issue_number" "$repo_slug") || {
		printf 'PR_LOOKUP_UNCERTAIN: open PR lookup failed for issue #%s in %s; dispatch is blocked\n' \
			"$issue_number" "$repo_slug"
		return 0
	}

	local issue_ref_pattern healthy_state_pattern blocked_state_pattern
	issue_ref_pattern="([^[:alnum:]_]|^)((close[sd]?|fix(e[sd])?|resolve[sd]?|for|refs?):?[[:space:]]+([a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+)?#${issue_number}|GH#${issue_number}|#${issue_number})([^[:alnum:]_]|$)"
	healthy_state_pattern="^(CLEAN|HAS_HOOKS|UNSTABLE|BEHIND)$"
	blocked_state_pattern="^(DIRTY|BLOCKED|CONFLICTING)$"

	draft_pr=$(printf '%s' "$pr_json" | jq -r \
		--arg issue_pattern "$issue_ref_pattern" '
		def names: [.labels[]?.name];
		def protected: names | any(
			. == "origin:interactive" or . == "hold-for-review" or
			. == "no-auto-dispatch" or . == "needs-maintainer-review"
		);
		def worker_owned: names | any(. == "origin:worker" or . == "origin:worker-takeover");
		[
			.[] | select(
				(.isDraft == true) and
				([.title?, .body?] | map(strings) | any(test($issue_pattern; "i")))
			)
		] | .[0] |
		if . then "\(.number)|\(if worker_owned and (protected | not) then "worker" else "protected" end)"
		else "" end' 2>/dev/null) || draft_pr=""
	if [[ -n "$draft_pr" ]]; then
		draft_pr_number="${draft_pr%%|*}"
		draft_pr_kind="${draft_pr#*|}"
		if [[ "$draft_pr_kind" == "worker" ]]; then
			printf 'WORKER_DRAFT_CHECKPOINT: draft PR #%s is a durable checkpoint for issue #%s; ordinary redispatch is blocked\n' \
				"$draft_pr_number" "$issue_number"
			return 0
		fi
		printf 'draft PR #%s is a durable checkpoint for issue #%s; ordinary redispatch is blocked\n' \
			"$draft_pr_number" "$issue_number"
		return 0
	fi

	match_pr=$(printf '%s' "$pr_json" | jq -r \
		--arg issue_pattern "$issue_ref_pattern" \
		--arg healthy_pattern "$healthy_state_pattern" \
		--arg blocked_pattern "$blocked_state_pattern" \
		'def complete_planning_only_scope:
			(.changedFiles // 0) as $changed |
			([.files[]?.path] | length) as $returned |
			($changed > 0) and ($returned == $changed) and
			([.files[]?.path] | all(.[]; test("^(TODO\\.md$|todo/)")));
		[
			.[] | select(
				(.isDraft // false | not) and
				((.reviewDecision // "") != "CHANGES_REQUESTED") and
				(((.mergeStateStatus // "") | test($blocked_pattern) | not)) and
				(
					((.reviewDecision // "") == "APPROVED") or
					((.mergeStateStatus // "") | test($healthy_pattern)) or
					((.mergeable // "") == "MERGEABLE")
				) and
				(((.title // "") | test($issue_pattern; "i")) or ((.body // "") | test($issue_pattern; "i"))) and
				(complete_planning_only_scope | not)
			)
		] | .[0].number // empty' 2>/dev/null) || match_pr=""

	if [[ -n "$match_pr" ]]; then
		printf 'open PR #%s is approved or mergeable for issue #%s\n' "$match_pr" "$issue_number"
		return 0
	fi
	return 1
}

#######################################
# has_open_pr Check 1: Open PRs with commits referencing this issue.
#
# The source of truth for "this PR solves this issue" is the commit messages,
# not the PR body. PR bodies are written at creation time (often from templates)
# and may mention issues for context without solving them. Commit messages are
# attached to actual code changes.
#
# GitHub auto-close works from commit messages on merge to default branch, so
# moving closing keywords from PR body to commits changes nothing for auto-close
# but eliminates false-positive dedup blocks.
#
# Args: $1 = issue number, $2 = repo slug
# Returns: exit 0 if an open PR matches (prints reason), exit 1 if no match
#######################################
_has_open_pr_check_open_commits() {
	local issue_number="$1"
	local repo_slug="$2"

	local open_pr_json open_pr_count
	open_pr_json=$(_ddpr_graphql_open_commits "$repo_slug") || {
		printf 'PR_LOOKUP_UNCERTAIN: open PR commit lookup failed for issue #%s in %s; dispatch is blocked\n' \
			"$issue_number" "$repo_slug"
		return 0
	}
	open_pr_count=$(printf '%s' "$open_pr_json" | jq 'length' 2>/dev/null) || open_pr_count=0
	[[ "$open_pr_count" =~ ^[0-9]+$ ]] || open_pr_count=0
	[[ "$open_pr_count" -eq 0 ]] && return 1

	# Match: closing keyword + #NNN in commit messages, or GH#NNN/#NNN in PR title
	local close_pattern=""
	close_pattern=$(_ddpr_closing_keyword_pattern "$issue_number")
	local title_pattern="(GH#${issue_number}|#${issue_number})([^[:alnum:]_]|$)"

	local match_pr
	match_pr=$(printf '%s' "$open_pr_json" | jq -r --arg cp "$close_pattern" --arg tp "$title_pattern" \
		'[.[] | select(((.isDraft // false) | not) and (
			((.title // "") | test($tp)) or
			any((.commits // [])[]?; ((.messageHeadline // "") | test($cp; "i")))
		))
		] | .[0].number // empty' 2>/dev/null) || match_pr=""
	if [[ -n "$match_pr" ]]; then
		printf 'open PR #%s has commits targeting issue #%s\n' "$match_pr" "$issue_number"
		return 0
	fi
	return 1
}

#######################################
# has_open_pr Check 1b: OPEN PRs with closing-keyword in body (t2085).
#
# Mirrors Check 2 but scans --state open. Catches the standard framework
# convention where `full-loop-helper.sh commit-and-pr` writes
# `Resolves #NNN` into the PR body — Check 1's commit-subject matcher
# does NOT see this because the framework convention does not put
# closing keywords in commit subjects.
#
# Without this check, every routine implementation PR was invisible to
# `has_open_pr`, which left Layer 4 dedup blind to in-flight work and
# caused the marcusquinn-vs-alex-solovyev cross-runner duplicate-dispatch
# race observed on issue #18779 → PR #18906 (a duplicate worker was
# dispatched after PR #18906 was already open and waiting for review).
#
# Fetches up to 20 candidate PRs in a single call and filters locally
# with jq regex to avoid two failure modes from the prior --limit 1
# approach: (a) a false-positive first result causing the real match to
# be missed, and (b) unnecessary extra calls per keyword. The simpler
# "#NNN in:body" query lets GitHub's full-text search find candidates;
# the closing-keyword regex post-filter eliminates false positives such
# as version strings ("v3.5.670" matching issue #670).
# GH#19140 (review-followup on PR #18915).
#
# Args: $1 = issue number, $2 = repo slug
# Returns: exit 0 if an open PR closes this issue (prints reason), exit 1 if none
#######################################
_has_open_pr_check_open_body_keyword() {
	local issue_number="$1"
	local repo_slug="$2"

	local pr_json match_pr
	# Fetch up to 20 open PRs mentioning the issue in the body; body is
	# included in this single request to avoid separate gh pr view calls.
	pr_json=$(gh pr list --repo "$repo_slug" --state open \
		--search "#${issue_number} in:body" --limit 20 \
		--json number,body,isDraft 2>/dev/null) || pr_json="[]"

	# Match: closing keyword + optional whitespace + #NNN or owner/repo#NNN
	# followed by a non-word char or end-of-string (GH#18641 semantics).
	local close_pattern
	close_pattern=$(_ddpr_closing_keyword_pattern "$issue_number")

	match_pr=$(printf '%s' "$pr_json" | jq -r --arg pattern "$close_pattern" \
		'[.[] | select((.isDraft // false | not) and (.body // "" | test($pattern; "i")))] | .[0].number // empty' \
		2>/dev/null) || match_pr=""

	if [[ -n "$match_pr" ]]; then
		printf 'open PR #%s closes issue #%s via keyword in body\n' "$match_pr" "$issue_number"
		return 0
	fi
	return 1
}

#######################################
# has_open_pr Check 2: Merged PRs with closing-keyword in body.
#
# Fetches up to 20 candidate PRs in a single call and filters locally
# with jq regex, matching the same approach as Check 1b (GH#19140).
# Avoids the --limit 1 correctness bug where a false-positive first
# result from GitHub full-text search would mask the real matching PR.
# The "#NNN in:body" query finds candidates; the closing-keyword regex
# post-filter eliminates false positives (e.g. version strings like
# "v3.5.670" matching issue #670).
#
# Args: $1 = issue number, $2 = repo slug
# Returns: exit 0 if a merged PR closes this issue (prints reason), exit 1 if none
#######################################
_has_open_pr_check_merged_keywords() {
	local issue_number="$1"
	local repo_slug="$2"

	local pr_json match_pr
	# Fetch up to 20 merged PRs mentioning the issue in the body; body is
	# included in this single request to avoid separate gh pr view calls.
	pr_json=$(gh pr list --repo "$repo_slug" --state merged \
		--search "#${issue_number} in:body" --limit 20 \
		--json number,body 2>/dev/null) || pr_json="[]"

	# Match: closing keyword + optional whitespace + #NNN or owner/repo#NNN
	# followed by a non-word char or end-of-string (GH#18641 semantics).
	local close_pattern
	close_pattern=$(_ddpr_closing_keyword_pattern "$issue_number")

	match_pr=$(printf '%s' "$pr_json" | jq -r --arg pattern "$close_pattern" \
		'[.[] | select(.body // "" | test($pattern; "i"))] | .[0].number // empty' \
		2>/dev/null) || match_pr=""

	if [[ -n "$match_pr" ]]; then
		printf 'merged PR #%s references issue #%s via keyword\n' "$match_pr" "$issue_number"
		return 0
	fi
	return 1
}

#######################################
# has_open_pr Check 3: Task-ID title match on merged PRs.
#
# GH#18041 (t1957): When a merged PR matches by task ID, verify it actually
# targets the same issue. A task ID collision (counter reset, fabricated ID)
# produces a merged PR for a *different* issue — blocking dispatch forever.
#
# GH#18641 (planning-only awareness): The framework convention uses
# `For #NNN` / `Ref #NNN` in planning-only PR bodies (briefs, TODO entries,
# research docs) so the brief PR does NOT auto-close the real implementation
# issue. The previous bare `#NNN` body-reference check treated those as
# dispatch blockers, creating a deadlock: every brief PR permanently
# blocked dispatch on its own follow-up implementation issue.
#
# Semantic: a merged PR whose title matches the task ID blocks dispatch ONLY
# if the body contains a closing-keyword reference to the specific issue
# number (the same pattern used by Check 2 and by GitHub's own auto-close
# logic). Planning references (`For #`, `Ref #`) and unrelated-issue
# collisions both fall through to "allow dispatch".
#
# Args: $1 = issue number, $2 = repo slug, $3 = issue title
# Returns: exit 0 if a merged PR closes this issue (prints reason), exit 1 otherwise
#######################################
_has_open_pr_check_task_id_title() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"

	local task_id
	task_id=$(printf '%s' "$issue_title" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || true)
	[[ -z "$task_id" ]] && return 1

	local query pr_json pr_count pr_number
	query="${task_id} in:title"
	# Fetch number+body in one request to avoid a separate gh pr view call (GH#19124)
	pr_json=$(gh pr list --repo "$repo_slug" --state merged --search "$query" --limit 1 --json number,body 2>/dev/null) || pr_json="[]"
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
	[[ "$pr_count" -eq 0 ]] && return 1

	pr_number=$(printf '%s' "$pr_json" | jq -r '.[0].number // empty' 2>/dev/null)
	if [[ -z "$pr_number" ]]; then
		printf 'merged PR found by task id %s in title\n' "$task_id"
		return 0
	fi

	# Use the body already fetched in the initial gh pr list request and verify
	# it contains a closing-keyword reference to OUR specific issue number.
	# This mirrors the pattern in Check 2 and is the single source of truth for
	# "this PR closed this issue": if GitHub would auto-close it, we block;
	# otherwise we allow dispatch.
	local merged_pr_body
	merged_pr_body=$(printf '%s' "$pr_json" | jq -r '.[0].body // empty' 2>/dev/null)
	local close_pattern_check3=""
	close_pattern_check3=$(_ddpr_closing_keyword_pattern "$issue_number")
	if printf '%s' "$merged_pr_body" | grep -iqE "$close_pattern_check3"; then
		printf 'merged PR #%s found by task id %s in title\n' "$pr_number" "$task_id"
		return 0
	fi

	# The merged PR has the same task ID but does NOT close issue
	# #${issue_number} via a closing keyword. Two valid cases fall
	# through here: (a) task-ID collision (different issue), and
	# (b) planning-only brief (For #NNN / Ref #NNN body reference).
	# Both cases allow dispatch — the real implementation is not done.
	printf 'NO_CLOSE_REF: merged PR #%s has task id %s but does not close issue #%s via closing keyword — allowing dispatch\n' \
		"$pr_number" "$task_id" "$issue_number" >&2
	return 1
}

#######################################
# has_open_pr Check 4: merged implementation PR for superseded/consolidated issue.
#
# Consolidated worker specs can supersede an older issue after implementation
# already landed against that older issue using `For #NNN` (parent/phase style),
# leaving the new consolidated issue open and dispatchable. When the current
# issue body explicitly says it supersedes/consolidates another issue, treat a
# merged, non-planning PR referencing that related issue as dispatch-blocking
# evidence. This is intentionally a dispatch dedup signal only; issue closers
# must still run their own verification before closing anything.
#
# Args: $1 = issue number, $2 = repo slug
# Returns: exit 0 if merged related-issue PR evidence exists, exit 1 otherwise
#######################################
_has_open_pr_check_superseded_issue_pr() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_body=""
	# Operational children describe how to create a consolidated spec and inline
	# arbitrary historical text; they are not consolidated specs themselves.
	_ddpr_is_consolidation_task && return 1
	issue_body=$(_ddpr_issue_body_from_meta)
	[[ -n "$issue_body" ]] || return 1

	local related_issue="" pr_json="" match_pr=""
	while IFS= read -r related_issue; do
		[[ "$related_issue" =~ ^[0-9]+$ ]] || continue
		[[ "$related_issue" != "$issue_number" ]] || continue

		pr_json=$(gh pr list --repo "$repo_slug" --state merged \
			--search "#${related_issue}" --limit 20 \
			--json number,title,body,author 2>/dev/null) || pr_json="[]"

		local ref_pattern="(^|[^0-9])#${related_issue}([^0-9]|$)|GH#${related_issue}([^0-9]|$)"
		local planning_pattern="planning-only|pure planning|brief-only|brief for|files the brief|no code changes"
		local bump_title_pattern="^(chore(\\([^)]*\\))?:[[:space:]]+)?bump[[:space:]]+(.+[[:space:]]+from[[:space:]]+.+[[:space:]]+to[[:space:]]+.+|the[[:space:]]+.+[[:space:]]+group([[:space:]]+.*)?)$"
		match_pr=$(printf '%s' "$pr_json" | jq -r \
			--arg ref_pattern "$ref_pattern" \
			--arg planning_pattern "$planning_pattern" \
			--arg bump_title_pattern "$bump_title_pattern" '
			[
				.[] |
				(.title // "") as $title |
				(.body // "") as $body |
				(.author.login // "") as $author |
				select(
					(($title | test($ref_pattern; "i")) or ($body | test($ref_pattern; "i"))) and
					((($title + "\n" + $body) | test($planning_pattern; "i")) | not) and
					((
						(($author == "dependabot[bot]") or ($author == "renovate[bot]")) and
						($title | test($bump_title_pattern; "i"))
					) | not))
			] | .[0].number // empty' 2>/dev/null) || match_pr=""

		if [[ -n "$match_pr" ]]; then
			printf 'merged PR #%s references superseded issue #%s for consolidated issue #%s\n' \
				"$match_pr" "$related_issue" "$issue_number"
			return 0
		fi
	done < <(_ddpr_superseded_issue_refs "$issue_body")

	return 1
}

#######################################
# Check whether an issue already has merged PR evidence.
#
# IMPORTANT: This function returns exit 0 for BOTH open and merged PRs
# that reference the issue. This is correct for dispatch dedup (any PR
# blocks re-dispatch), but callers that close issues MUST independently
# verify mergedAt before acting — an open PR means work in progress,
# not work complete. See GH#17871 for the bug this caused.
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = issue title (optional; used for task-id fallback)
# Returns:
#   exit 0 if PR evidence exists — open OR merged (do NOT dispatch)
#   exit 1 if no PR evidence (safe to dispatch)
# Outputs:
#   single-line reason when evidence is found
# CALLERS: For issue closing, verify mergedAt after this returns 0.
#######################################
has_open_pr() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="${3:-}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	# t3043: parallelise the sub-checks. Previously serial (4x 3-10s =
	# 12-40s); now concurrent via temp files and background jobs. The common
	# case is "no PR evidence" where all 4 checks run — parallelising turns
	# 12-40s into max(3-10s) ≈ 3-10s (4x faster). When evidence IS found
	# early, the wasted parallel calls don't affect the critical path (the
	# candidate is blocked regardless).
	local _pr_tmpdir
	_pr_tmpdir=$(mktemp -d 2>/dev/null) || _pr_tmpdir="/tmp/pr-dedup-$$"
	mkdir -p "$_pr_tmpdir" 2>/dev/null || true

	# Launch all checks in parallel, each writing exit code + output to a file
	(
		_result=$(_has_open_pr_check_healthy_sibling "$issue_number" "$repo_slug" 2>/dev/null) && \
			printf '%s' "$_result" >"${_pr_tmpdir}/check0.out" || true
	) &
	local _pr_pid0=$!

	(
		_result=$(_has_open_pr_check_open_commits "$issue_number" "$repo_slug" 2>/dev/null) && \
			printf '%s' "$_result" >"${_pr_tmpdir}/check1.out" || true
	) &
	local _pr_pid1=$!

	(
		_result=$(_has_open_pr_check_open_body_keyword "$issue_number" "$repo_slug" 2>/dev/null) && \
			printf '%s' "$_result" >"${_pr_tmpdir}/check1b.out" || true
	) &
	local _pr_pid2=$!

	(
		_result=$(_has_open_pr_check_merged_keywords "$issue_number" "$repo_slug" 2>/dev/null) && \
			printf '%s' "$_result" >"${_pr_tmpdir}/check2.out" || true
	) &
	local _pr_pid3=$!

	(
		_result=$(_has_open_pr_check_task_id_title "$issue_number" "$repo_slug" "$issue_title" 2>/dev/null) && \
			printf '%s' "$_result" >"${_pr_tmpdir}/check3.out" || true
	) &
	local _pr_pid4=$!

	(
		_result=$(_has_open_pr_check_superseded_issue_pr "$issue_number" "$repo_slug" 2>/dev/null) && \
			printf '%s' "$_result" >"${_pr_tmpdir}/check4.out" || true
	) &
	local _pr_pid5=$!

	# Wait for all to complete
	wait "$_pr_pid0" 2>/dev/null || true
	wait "$_pr_pid1" 2>/dev/null || true
	wait "$_pr_pid2" 2>/dev/null || true
	wait "$_pr_pid3" 2>/dev/null || true
	wait "$_pr_pid4" 2>/dev/null || true
	wait "$_pr_pid5" 2>/dev/null || true

	# Check results — any hit means PR evidence exists
	local _check_file _check_output
	for _check_file in "${_pr_tmpdir}/check0.out" "${_pr_tmpdir}/check1.out" "${_pr_tmpdir}/check1b.out" \
		"${_pr_tmpdir}/check2.out" "${_pr_tmpdir}/check3.out" "${_pr_tmpdir}/check4.out"; do
		if [[ -f "$_check_file" ]]; then
			_check_output=$(cat "$_check_file" 2>/dev/null) || _check_output=""
			if [[ -n "$_check_output" ]]; then
				printf '%s\n' "$_check_output"
				rm -rf "$_pr_tmpdir" 2>/dev/null || true
				return 0
			fi
		fi
	done

	rm -rf "$_pr_tmpdir" 2>/dev/null || true
	return 1
}
