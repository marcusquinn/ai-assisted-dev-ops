#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Triage Dispatch -- Consolidation dispatch, cross-runner advisory lock,
# child issue creation, and backfill sweep.
# =============================================================================
# Extracted from pulse-triage.sh as part of the file-size-debt split
# (parent: GH#21146, child: GH#21326).
#
# Functions in this sub-library:
#   - _consolidation_emit_skip (t3050 — pre-flight skip helper)
#   - _consolidation_count_merged_children (t3050 — pre-flight child PR scanner)
#   - _consolidation_skip_if_resolved (t3050 — pre-flight resolved-parent gate)
#   - _compose_consolidation_worker_instructions
#   - _compose_consolidation_child_body
#   - _ensure_consolidation_labels
#   - _consolidation_lock_marker_body
#   - _consolidation_lock_markers
#   - _consolidation_lock_self_login
#   - _consolidation_lock_label_present
#   - _consolidation_lock_release
#   - _consolidation_lock_acquire
#   - _create_consolidation_child_issue
#   - _post_consolidation_dispatch_comment
#   - _consolidation_ttl_sweep_one
#   - _backfill_stale_consolidation_labels
#
# Usage: source "${SCRIPT_DIR}/pulse-triage-dispatch.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, gh_create_issue,
#     gh_issue_comment, gh_issue_list, etc.)
#   - pulse-triage-cache.sh (_gh_idempotent_comment)
#   - pulse-triage-evaluation.sh (_consolidation_child_exists,
#     _consolidation_resolving_pr_exists, _consolidation_substantive_comments,
#     _format_consolidation_comments_section)
#   - LOGFILE, REPOS_JSON, CONSOLIDATION_LOCK_TTL_HOURS,
#     CONSOLIDATION_LOCK_TIEBREAK_WAIT_SEC (set by orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_TRIAGE_DISPATCH_LIB_LOADED:-}" ]] && return 0
_PULSE_TRIAGE_DISPATCH_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# t1982: Compose the "What to do" instructions and "Constraints" sections
# for the consolidation-task child body. Called by _compose_consolidation_child_body.
#
# Args: $1=parent_num $2=repo_slug $3=authors_line
#######################################
_compose_consolidation_worker_instructions() {
	local parent_num="$1"
	local repo_slug="$2"
	local authors_line="$3"

	cat <<EOF
## What to do

1. **Read the parent body and substantive comments inlined below.** Identify:
   - The original problem statement
   - Scope modifications added by commenters (additions, corrections, clarifications)
   - Resolved questions, rejected ideas, or superseded decisions
   - The final agreed-upon approach

2. **Compose a single coherent issue body** in the aidevops brief format (see \`templates/brief-template.md\`):
   - \`## What\` — the deliverable
   - \`## Why\` — the problem and rationale
   - \`## How\` — approach with explicit file paths and line references
   - \`## Acceptance Criteria\` — testable checkboxes
   - \`## Context & Decisions\` — which commenter contributed which insight (attribution matters)
   - \`## Contributors\` — a cc line @-mentioning every author from the list below

   Start the merged body with: \`_Supersedes #${parent_num} — this issue is the consolidated spec._\`

3. **File the new consolidated issue:**

\`\`\`bash
gh issue create --repo "${repo_slug}" \\
  --title "consolidated: <concise description derived from the merged spec>" \\
  --label "consolidated,origin:worker,auto-dispatch,<copy relevant labels from parent, excluding needs-consolidation, consolidation-task, and origin:interactive>" \\
  --body "<merged body from step 2>"
\`\`\`

**Note (GH#18670):** \`origin:worker\` is mandatory on this label list — consolidated issues are pulse-generated artifacts, not interactive maintainer work. Without it, the issue is born \`origin:interactive\` (raw \`gh issue create\` has no origin auto-detection), which triggers the GH#18352 dispatch-dedup block and drains the queue.

**Dispatch handoff:** \`auto-dispatch\` is also mandatory. The consolidated successor marker and this explicit handoff must both be present before \`_has_consolidated_label\` permits implementation dispatch.

   Capture the new issue number as \$NEW_NUM.

4. **Close the parent #${parent_num}:**

\`\`\`bash
gh issue comment ${parent_num} --repo "${repo_slug}" \\
  --body "Superseded by #\$NEW_NUM. The merged spec is inlined on the new issue — continue discussion there."
gh issue edit ${parent_num} --repo "${repo_slug}" \\
  --add-label "consolidated" --remove-label "needs-consolidation"
gh issue close ${parent_num} --repo "${repo_slug}" --reason "not planned"
\`\`\`

5. **Close this consolidation-task issue** with a summary comment:

\`\`\`bash
gh issue comment \$THIS_ISSUE --repo "${repo_slug}" \\
  --body "Consolidation complete. Parent: #${parent_num} → New: #\$NEW_NUM. Contributors @-mentioned: ${authors_line}."
gh issue close \$THIS_ISSUE --repo "${repo_slug}" --reason "completed"
\`\`\`

## Constraints

- **Do NOT read #${parent_num}** — it is inlined below. Reading it wastes the token budget.
- **Preserve all substantive content.** Merging is not summarising. If a comment adds a constraint, that constraint must appear in the merged body.
- **Preserve author attribution** for specific contributions: "per @user1: …".
- **No PR is required.** This is an operational task. The completion signal is the new issue number + parent closure + self-close.
- **Contributors to @-mention** on the new issue: ${authors_line}
EOF
}

#######################################
# t1982: Compose a self-contained consolidation-task child issue body.
#
# The worker reading this body must NOT need to read the parent — all
# required content is inlined here. Includes:
#   - Consolidation target marker (for dedup lookup)
#   - Explicit worker instructions (gh commands)
#   - Parent body verbatim
#   - Substantive comments verbatim (author + timestamp headers)
#   - Contributors cc line (@mentions)
#
# Args: parent_num repo_slug parent_title parent_body substantive_json authors_csv parent_labels
#######################################
_compose_consolidation_child_body() {
	local parent_num="$1"
	local repo_slug="$2"
	local parent_title="$3"
	local parent_body="$4"
	local substantive_json="$5"
	local authors_csv="$6"
	local parent_labels="$7"

	local comments_section
	comments_section=$(_format_consolidation_comments_section "$substantive_json")

	local authors_line="${authors_csv:-_no substantive authors detected_}"
	local parent_body_section="${parent_body:-_(parent body was empty)_}"

	local instructions_block
	instructions_block=$(_compose_consolidation_worker_instructions \
		"$parent_num" "$repo_slug" "$authors_line")

	cat <<EOF
## Consolidation target: #${parent_num}

**Parent issue:** #${parent_num} in \`${repo_slug}\`
**Parent title:** ${parent_title}
**Parent labels:** \`${parent_labels}\`

> You do **NOT** need to read #${parent_num}. Everything required is inlined below.
> Reading the parent wastes the token budget and is explicitly disallowed for this task.

${instructions_block}

## Parent body (verbatim)

${parent_body_section}

## Substantive comments (verbatim, in chronological order)

${comments_section}

---

_Self-contained dispatch packet generated by \`_dispatch_issue_consolidation()\` in \`pulse-triage.sh\` (t1982). Everything above is sufficient — do not read #${parent_num}._
EOF
}

#######################################
# t1982: Ensure the three GitHub labels required for the consolidation
# workflow exist on the given repo. Idempotent (uses --force).
# Called by _dispatch_issue_consolidation.
#
# Args: $1=repo_slug
#######################################
_ensure_consolidation_labels() {
	local repo_slug="$1"
	gh label create "needs-consolidation" \
		--repo "$repo_slug" \
		--description "Issue held from dispatch pending comment consolidation" \
		--color "FBCA04" --force 2>/dev/null || true
	gh label create "consolidation-task" \
		--repo "$repo_slug" \
		--description "Operational task: merge parent issue body + comments into a consolidated child issue" \
		--color "C5DEF5" --force 2>/dev/null || true
	gh label create "consolidated" \
		--repo "$repo_slug" \
		--description "Issue superseded by a consolidated child" \
		--color "0E8A16" --force 2>/dev/null || true
	# t2151: cross-runner advisory lock for consolidation dispatch. Applied by
	# `_consolidation_lock_acquire` before child issue creation; treated as an
	# active-claim signal by `dispatch-dedup-helper.sh is-assigned` so unrelated
	# dispatch paths can't sneak past during the write window.
	gh label create "consolidation-in-progress" \
		--repo "$repo_slug" \
		--description "Another runner is creating a consolidation child issue (cross-runner advisory lock)" \
		--color "CFD3D7" --force 2>/dev/null || true
	return 0
}

#######################################
# t2151: Cross-runner advisory lock — marker comment protocol.
#
# Two pulse runners on different hosts can hit the same parent issue within
# the same consolidation window. Neither sees the other's in-flight gh writes
# directly, so both pass local `_consolidation_child_exists` and both create
# a child. Production evidence: parent #19321 → #19341 (marcusquinn) +
# #19367 (alex-solovyev, 55 min later).
#
# Protocol:
#   1. acquire: apply `consolidation-in-progress` label, post a signed
#      marker comment (HTML-comment prefix + runner login + ISO timestamp),
#      wait briefly for any competitor's marker to flush, re-read comments.
#   2. tiebreak: if multiple markers are present, lexicographic actor-login
#      comparison picks the single winner. Last-writer-loses when logins are
#      identical is impossible here (GitHub logins are unique), but if the
#      same runner somehow posts twice, the older comment wins.
#   3. release: remove the label and delete our marker comment. Release
#      happens after successful child creation OR on any failure path.
#
# Why a comment marker plus a label, not just the label?
#   The label alone is not enough for tiebreaking: `gh issue edit --add-label`
#   is idempotent — after both runners apply the label, we cannot tell from
#   the label alone who "got there first". A comment with a unique marker
#   body and a runner-specific signature gives us a deterministic tiebreaker
#   that works under real concurrent-API-call conditions, and crucially
#   leaves an audit trail of every lock attempt.
#
# Why not rely on `gh issue edit` being atomic?
#   `--add-label X` is atomic at the API-call surface, but two runners calling
#   it near-simultaneously both observe their own call as "the label didn't
#   exist, now it does". GitHub doesn't return a "label was already present"
#   signal on the REST API. Hence the marker-comment protocol.
#######################################

# t2151: generate the marker comment text for a lock acquisition.
# Format: `<!-- consolidation-lock:runner=LOGIN ts=ISO8601 -->` on a single line.
# The single-line HTML-comment prefix is the stable anchor that filter regexes
# and grep-style tests can match without ambiguity.
_consolidation_lock_marker_body() {
	local self_login="$1"
	local iso_ts="$2"
	printf '<!-- consolidation-lock:runner=%s ts=%s -->\n_Cross-runner advisory lock acquired for consolidation dispatch (t2151). This comment will be removed when the lock is released._' \
		"$self_login" "$iso_ts"
	return 0
}

# t2151: fetch all lock marker comments on the parent. Returns a JSON array
# of {id, login, created_at} objects to stdout, sorted by created_at ascending.
# Empty array on API failure.
_consolidation_lock_markers() {
	local parent_num="$1"
	local repo_slug="$2"
	gh api "repos/${repo_slug}/issues/${parent_num}/comments" --paginate \
		--jq '[.[] | select(.body | test("^<!-- consolidation-lock:runner=[A-Za-z0-9_-]+ ts="))
			| {id: .id, body: .body, created_at: .created_at,
				runner: (.body | capture("^<!-- consolidation-lock:runner=(?<r>[A-Za-z0-9_-]+)") | .r)}]
			| sort_by(.created_at)' 2>/dev/null || printf '[]'
	return 0
}

# t2151: determine self login — the current runner's GitHub login. Workers
# and pulse runners authenticate via `gh auth login`; the login returned by
# `gh api user` is the same one that appears in comment.user.login. Returns
# empty on failure; callers MUST treat empty as "cannot acquire lock" and
# skip dispatch rather than proceed blindly.
_consolidation_lock_self_login() {
	# Prefer an explicit override for tests.
	if [[ -n "${CONSOLIDATION_LOCK_SELF_LOGIN_OVERRIDE:-}" ]]; then
		printf '%s' "$CONSOLIDATION_LOCK_SELF_LOGIN_OVERRIDE"
		return 0
	fi
	gh api user --jq '.login' 2>/dev/null || true
	return 0
}

# t2151: determine if parent currently carries the lock label.
# Args: $1=parent_num $2=repo_slug
# Returns: 0 if label is present, 1 otherwise.
_consolidation_lock_label_present() {
	local parent_num="$1"
	local repo_slug="$2"
	local labels_csv
	labels_csv=$(gh issue view "$parent_num" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || labels_csv=""
	[[ ",${labels_csv}," == *",consolidation-in-progress,"* ]]
}

# t2151: release the lock — delete our marker comment(s) and remove the label
# if no other runner's marker is present. Safe to call even if acquire failed
# (idempotent). Never fails the caller — release best-effort.
#
# Args: $1=parent_num $2=repo_slug $3=self_login
_consolidation_lock_release() {
	local parent_num="$1"
	local repo_slug="$2"
	local self_login="$3"

	[[ -n "$parent_num" && -n "$repo_slug" ]] || return 0

	local markers_json
	markers_json=$(_consolidation_lock_markers "$parent_num" "$repo_slug")
	[[ -n "$markers_json" ]] || markers_json="[]"

	# Delete every marker that belongs to us.
	local self_marker_ids
	self_marker_ids=$(printf '%s' "$markers_json" |
		jq -r --arg me "$self_login" '.[] | select(.runner == $me) | .id' 2>/dev/null) || self_marker_ids=""
	local mid
	while IFS= read -r mid; do
		[[ -z "$mid" ]] && continue
		gh api -X DELETE "repos/${repo_slug}/issues/comments/${mid}" >/dev/null 2>&1 || true
	done <<<"$self_marker_ids"

	# If no other runner's marker remains, drop the lock label. Otherwise a
	# competing runner is still inside its own acquire/dispatch window — don't
	# clear the label out from under them.
	local other_count
	other_count=$(printf '%s' "$markers_json" |
		jq -r --arg me "$self_login" '[.[] | select(.runner != $me)] | length' 2>/dev/null) || other_count=0
	[[ "$other_count" =~ ^[0-9]+$ ]] || other_count=0
	if [[ "$other_count" -eq 0 ]]; then
		gh issue edit "$parent_num" --repo "$repo_slug" \
			--remove-label "consolidation-in-progress" >/dev/null 2>&1 || true
	fi
	return 0
}

# t2151: acquire the cross-runner lock. See protocol overview above.
#
# Args: $1=parent_num $2=repo_slug
# Returns:
#   0 — lock acquired, caller MUST proceed with child creation and
#       call _consolidation_lock_release after (success or failure).
#   1 — lock held by another runner or self_login unavailable; caller
#       MUST skip dispatch.
_consolidation_lock_acquire() {
	local parent_num="$1"
	local repo_slug="$2"

	[[ -n "$parent_num" && -n "$repo_slug" ]] || return 1

	local self_login
	self_login=$(_consolidation_lock_self_login)
	if [[ -z "$self_login" ]]; then
		# Cannot lock without knowing our identity — fail-closed: block
		# dispatch rather than create a duplicate. A transient `gh auth`
		# issue self-heals within one pulse cycle at zero cost.
		echo "[pulse-wrapper] Consolidation lock: gh api user failed for #${parent_num} in ${repo_slug} — skipping dispatch (fail-closed)" >>"$LOGFILE"
		return 1
	fi

	# Apply label first — cheapest signal for the fast-path competitor
	# who is about to call `_consolidation_child_exists`.
	gh issue edit "$parent_num" --repo "$repo_slug" \
		--add-label "consolidation-in-progress" >/dev/null 2>&1 || true

	# Post our marker. Embed the current ISO timestamp.
	local iso_ts
	iso_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || iso_ts=""
	local marker_body
	marker_body=$(_consolidation_lock_marker_body "$self_login" "$iso_ts")
	gh_issue_comment "$parent_num" --repo "$repo_slug" \
		--body "$marker_body" >/dev/null 2>&1 || {
		# Comment post failed — can't tiebreak without our marker being
		# visible. Roll back by clearing the label and skip dispatch.
		gh issue edit "$parent_num" --repo "$repo_slug" \
			--remove-label "consolidation-in-progress" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Consolidation lock: marker comment post failed for #${parent_num} in ${repo_slug} — rolled back label, skipping dispatch" >>"$LOGFILE"
		return 1
	}

	# Give any concurrent competitor a short window to flush their marker.
	# `sleep 0` on tiebreak_wait=0 is a no-op — used by unit tests.
	local wait_sec="${CONSOLIDATION_LOCK_TIEBREAK_WAIT_SEC:-2}"
	[[ "$wait_sec" =~ ^[0-9]+$ ]] || wait_sec=2
	if [[ "$wait_sec" -gt 0 ]]; then
		sleep "$wait_sec" 2>/dev/null || true
	fi

	# Re-read markers and tiebreak.
	local markers_json
	markers_json=$(_consolidation_lock_markers "$parent_num" "$repo_slug")
	[[ -n "$markers_json" ]] || markers_json="[]"

	# Count distinct runners. If only one (us), we won trivially.
	local distinct_runners
	distinct_runners=$(printf '%s' "$markers_json" |
		jq -r '[.[].runner] | unique | length' 2>/dev/null) || distinct_runners=0
	[[ "$distinct_runners" =~ ^[0-9]+$ ]] || distinct_runners=0

	if [[ "$distinct_runners" -le 1 ]]; then
		# No competing runner — we own the lock.
		echo "[pulse-wrapper] Consolidation lock: acquired by ${self_login} on #${parent_num} in ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	# Tiebreak: lexicographically lowest login wins. Deterministic without
	# relying on clock skew between runners.
	local winner_login
	winner_login=$(printf '%s' "$markers_json" |
		jq -r '[.[].runner] | unique | sort | .[0]' 2>/dev/null) || winner_login=""

	if [[ "$winner_login" == "$self_login" ]]; then
		echo "[pulse-wrapper] Consolidation lock: won tiebreaker on #${parent_num} in ${repo_slug} (self=${self_login}, competitors=$(printf '%s' "$markers_json" | jq -r '[.[].runner] | unique | join(",")' 2>/dev/null))" >>"$LOGFILE"
		return 0
	fi

	# We lost. Release our marker but leave the label (winner still needs it).
	echo "[pulse-wrapper] Consolidation lock: lost tiebreaker on #${parent_num} in ${repo_slug} (self=${self_login}, winner=${winner_login}) — rolling back our marker" >>"$LOGFILE"
	local self_marker_ids
	self_marker_ids=$(printf '%s' "$markers_json" |
		jq -r --arg me "$self_login" '.[] | select(.runner == $me) | .id' 2>/dev/null) || self_marker_ids=""
	local mid
	while IFS= read -r mid; do
		[[ -z "$mid" ]] && continue
		gh api -X DELETE "repos/${repo_slug}/issues/comments/${mid}" >/dev/null 2>&1 || true
	done <<<"$self_marker_ids"
	return 1
}

#######################################
# t1982: File the consolidation child issue via a temp body file (avoids
# argv length limits on long parent bodies with many comments).
# Prints the child issue number to stdout on success, empty on failure.
# Called by _dispatch_issue_consolidation.
#
# Args: $1=repo_slug $2=issue_number $3=child_body
#######################################
_create_consolidation_child_issue() {
	local repo_slug="$1"
	local issue_number="$2"
	local child_body="$3"

	local body_file
	body_file=$(mktemp -t consolidation-child.XXXXXX) || {
		echo "[pulse-wrapper] ERROR: mktemp failed for consolidation child body (#${issue_number})" >>"$LOGFILE"
		return 1
	}
	printf '%s\n' "$child_body" >"$body_file"

	local child_url
	# t2115: Use gh_create_issue wrapper for origin label + signature auto-append.
	# origin:worker is kept in --label for explicitness (wrapper deduplicates).
	child_url=$(gh_create_issue --repo "$repo_slug" \
		--title "consolidation-task: merge thread on #${issue_number} into single spec" \
		--label "consolidation-task,auto-dispatch,origin:worker,tier:standard" \
		--body-file "$body_file" 2>/dev/null) || child_url=""
	rm -f "$body_file"

	# gh issue create prints the URL on success; extract the number.
	if [[ -n "$child_url" ]]; then
		printf '%s' "${child_url##*/}"
	fi
	return 0
}

#######################################
# t1982: Flag parent issue with needs-consolidation label and post the
# idempotent pointer comment linking to the newly created child issue.
# Called by _dispatch_issue_consolidation after successful child creation.
#
# Args: $1=issue_number $2=repo_slug $3=child_num $4=authors_csv
#######################################
_post_consolidation_dispatch_comment() {
	local issue_number="$1"
	local repo_slug="$2"
	local child_num="$3"
	local authors_csv="$4"

	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "needs-consolidation" 2>/dev/null || true

	local parent_comment_body="## Issue Consolidation Dispatched

A consolidation task has been filed as **#${child_num}**. It contains the full body and substantive comments of this issue inline, plus instructions for a worker to produce a merged spec, file it as a new issue, @mention all contributors, and close this issue as superseded.

**What happens next:**

1. A worker picks up #${child_num} on the next pulse cycle
2. It files a new consolidated issue with the merged spec
3. It comments \"Superseded by #NNN\" here, applies the \`consolidated\` label, and closes this issue
4. Contributors (${authors_csv:-_none detected_}) are @-mentioned on the new issue

_Automated by \`_dispatch_issue_consolidation()\` in \`pulse-triage.sh\` (t1982)_"

	_gh_idempotent_comment "$issue_number" "$repo_slug" \
		"## Issue Consolidation Dispatched" "$parent_comment_body"
	return 0
}

#######################################
# t2151: Clear stale `consolidation-in-progress` lock labels whose oldest
# lock-marker comment is older than CONSOLIDATION_LOCK_TTL_HOURS. Covers
# the case where the runner that acquired the lock crashed or lost network
# between `_consolidation_lock_acquire` and `_consolidation_lock_release`,
# leaving the lock wedged.
#
# Called from _backfill_stale_consolidation_labels so every pulse cycle
# sweeps all pulse-enabled repos for stuck locks at zero marginal cost.
#
# Args: $1=repo_slug, $2=issue_number
# Returns: 0 if lock was cleared, 1 if lock was fresh (no action taken).
# Side effect: emits a log line when clearing.
#######################################
_consolidation_ttl_sweep_one() {
	local slug="$1"
	local num="$2"
	local ttl_hours="${CONSOLIDATION_LOCK_TTL_HOURS:-6}"
	[[ "$ttl_hours" =~ ^[0-9]+$ ]] || ttl_hours=6

	# Get the oldest lock-marker timestamp.
	local markers_json
	markers_json=$(_consolidation_lock_markers "$num" "$slug")
	[[ -n "$markers_json" ]] || markers_json="[]"

	local oldest_iso
	oldest_iso=$(printf '%s' "$markers_json" |
		jq -r '.[0].created_at // empty' 2>/dev/null) || oldest_iso=""

	if [[ -z "$oldest_iso" ]]; then
		# Label present but no marker comment — orphaned from a previous
		# deploy or manual edit. Clear it as well (nothing to tiebreak).
		gh issue edit "$num" --repo "$slug" \
			--remove-label "consolidation-in-progress" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Consolidation lock TTL sweep: cleared orphan (no marker) on #${num} in ${slug}" >>"$LOGFILE"
		return 0
	fi

	# Compute oldest-epoch. Prefer GNU date -d; fall back to BSD date -j.
	local oldest_epoch=""
	oldest_epoch=$(date -u -d "$oldest_iso" +'%s' 2>/dev/null) || oldest_epoch=""
	if [[ -z "$oldest_epoch" ]]; then
		oldest_epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$oldest_iso" +'%s' 2>/dev/null) || oldest_epoch=""
	fi
	# If date parsing fails entirely, fall-open (treat as fresh). A real
	# stuck lock will trip on the NEXT pulse cycle once the comment-ISO
	# parser recovers — preferable to false-clearing an in-flight lock.
	[[ -n "$oldest_epoch" ]] || return 1

	local now_epoch
	now_epoch=$(date -u +'%s' 2>/dev/null) || now_epoch=0
	local age_seconds=$((now_epoch - oldest_epoch))
	local ttl_seconds=$((ttl_hours * 3600))

	if [[ "$age_seconds" -lt "$ttl_seconds" ]]; then
		return 1
	fi

	# Lock is stale — clear the label and delete ALL markers (nobody is
	# coming back for them; the next dispatcher starts from scratch).
	gh issue edit "$num" --repo "$slug" \
		--remove-label "consolidation-in-progress" >/dev/null 2>&1 || true
	local mid
	while IFS= read -r mid; do
		[[ -z "$mid" ]] && continue
		gh api -X DELETE "repos/${slug}/issues/comments/${mid}" >/dev/null 2>&1 || true
	done < <(printf '%s' "$markers_json" | jq -r '.[].id' 2>/dev/null)

	echo "[pulse-wrapper] Consolidation lock TTL sweep: cleared stale lock on #${num} in ${slug} (age=${age_seconds}s, ttl=${ttl_seconds}s)" >>"$LOGFILE"
	return 0
}

#######################################
# t1982/t2151: Backfill pass for stuck needs-consolidation issues.
#
# The re-evaluation pass (_reevaluate_consolidation_labels) only *clears*
# stale labels when the comment filter no longer triggers. Issues flagged
# before this fix landed never got a consolidation-task child created,
# because the old _dispatch_issue_consolidation() just labelled and
# returned. Those issues sit forever behind the needs-* dispatch filter.
#
# This pass sweeps every open needs-consolidation issue without a linked
# consolidation-task child and dispatches one retroactively.
#
# t2151: Also sweeps every open `consolidation-in-progress` issue and
# clears the lock label when the oldest lock-marker comment is older than
# CONSOLIDATION_LOCK_TTL_HOURS (default 6h). Closes the "runner crashed
# mid-dispatch" failure mode in which the lock would otherwise sit wedged
# until a human notices.
#
# Runs every pulse cycle alongside _reevaluate_consolidation_labels.
# Cheap: one gh issue list per repo + one child-exists lookup per labelled
# issue, then dispatch only for those missing a child.
#######################################
_backfill_stale_consolidation_labels() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_backfilled=0 total_cleared_stale=0 total_locks_expired=0
	local maintenance_flag="" pulse_flag="" rest_deferred=0
	while IFS='|' read -r slug rpath maintenance_flag pulse_flag; do
		[[ -n "$slug" ]] || continue
		if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 \
			|| ! repo_allows_pulse_write_actions "$slug"; then
			continue
		fi
		if ! _pte_rest_core_deferrable_allows_next "consolidation_backfill_repo:${slug}"; then
			rest_deferred=1
			break
		fi

		# t2151: TTL sweep for stuck `consolidation-in-progress` labels.
		# Separate query from needs-consolidation because a lock can be held
		# on a parent that already has both labels (lock was acquired before
		# needs-consolidation was applied) or only the lock (acquire path
		# where child creation failed after lock but before flag-parent).
		local locked_issues_json
		locked_issues_json=$(gh_issue_list --repo "$slug" --state open \
			--label "consolidation-in-progress" \
			--json number --limit 50 2>/dev/null) || locked_issues_json='[]'
		local locked_num
		while IFS= read -r locked_num; do
			[[ "$locked_num" =~ ^[0-9]+$ ]] || continue
			if ! _pte_rest_core_deferrable_allows_next "consolidation_lock_issue:${slug}#${locked_num}"; then
				rest_deferred=1
				break
			fi
			if _consolidation_ttl_sweep_one "$slug" "$locked_num"; then
				total_locks_expired=$((total_locks_expired + 1))
			fi
		done < <(printf '%s' "$locked_issues_json" | jq -r '.[]?.number // ""' 2>/dev/null)
		[[ "$rest_deferred" -eq 0 ]] || break
		[[ "$maintenance_flag" == "false" || "$pulse_flag" != "true" ]] && continue
		if ! _pte_rest_core_deferrable_allows_next "consolidation_backfill_scan:${slug}"; then
			rest_deferred=1
			break
		fi

		local issues_json
		issues_json=$(gh_issue_list --repo "$slug" --state open \
			--label "needs-consolidation" \
			--json number,labels --limit 50 2>/dev/null) || issues_json='[]'

		while IFS='|' read -r num labels_csv; do
			[[ "$num" =~ ^[0-9]+$ ]] || continue
			if ! _pte_rest_core_deferrable_allows_next "consolidation_backfill_issue:${slug}#${num}"; then
				rest_deferred=1
				break
			fi

			# t2144 (A3): Defense in depth — skip and auto-clear if the
			# parent already carries `consolidated`. _issue_needs_consolidation
			# short-circuits on this label (line ~263), but that function
			# won't clean up the stale `needs-consolidation` label if both
			# are present; do it here explicitly.
			if [[ ",${labels_csv}," == *",consolidated,"* ]]; then
				gh issue edit "$num" --repo "$slug" \
					--remove-label "needs-consolidation" >/dev/null 2>&1 || true
				total_cleared_stale=$((total_cleared_stale + 1))
				continue
			fi

			# t2144 (A2): Unify the dispatch guard. Prior to this, backfill
			# ran a bare label-lookup + open-child-exists check and dispatched
			# on anything that passed, bypassing the filter that
			# _issue_needs_consolidation enforces on the main pre-dispatch
			# path. The delegation here:
			#   - auto-clears the label when the filter no longer triggers
			#     (via the was_already_labeled branch inside the helper)
			#   - short-circuits on an open or recently-closed child via
			#     _consolidation_child_exists (now grace-windowed, A4)
			#   - short-circuits on the `consolidated` label
			# Net effect: backfill only dispatches when dispatch is actually
			# warranted under the current filter, eliminating the cascade.
			if ! _issue_needs_consolidation "$num" "$slug"; then
				continue
			fi
			if _dispatch_issue_consolidation "$num" "$slug" "$rpath"; then
				total_backfilled=$((total_backfilled + 1))
			fi
		done < <(printf '%s' "$issues_json" | jq -r '.[] | "\(.number)|\([.labels[].name] | join(","))"' 2>/dev/null)
		[[ "$rest_deferred" -eq 0 ]] || break
	done < <(jq -r '.initialized_repos[] | select((.local_only // false) == false and .slug != "") | "\(.slug)|\(.path // "")|\(if .maintenance == false then false else true end)|\(.pulse // false)"' "$repos_json" 2>/dev/null)

	if [[ "$total_backfilled" -gt 0 ]]; then
		echo "[pulse-wrapper] Consolidation backfill: dispatched ${total_backfilled} stale consolidation child issue(s)" >>"$LOGFILE"
	fi
	if [[ "$total_cleared_stale" -gt 0 ]]; then
		echo "[pulse-wrapper] Consolidation backfill: cleared ${total_cleared_stale} stale needs-consolidation label(s) on already-consolidated parents (t2144)" >>"$LOGFILE"
	fi
	if [[ "$total_locks_expired" -gt 0 ]]; then
		echo "[pulse-wrapper] Consolidation backfill: cleared ${total_locks_expired} stale consolidation-in-progress lock(s) (t2151 TTL)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# t3050: Post the one-shot skip-marker comment + log line for an aborted
# consolidation pre-flight check. Keeps the per-gate emit logic out of the
# orchestrator so each gate stays a 4-5 line clause and the orchestrator
# stays under the 100-line function-complexity threshold.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - reason (one-line human description appended to skip marker)
#   $4 - log_tag (short token included in the log line for grep)
#
# Returns: 0 (always — caller treats this as the "skip" signal).
#######################################
_consolidation_emit_skip() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="$3"
	local log_tag="$4"
	local marker="<!-- consolidation-skipped -->"
	_gh_idempotent_comment "$issue_number" "$repo_slug" "$marker" \
		"${marker}
Skipping consolidation — ${reason}"
	echo "[pulse-wrapper] Consolidation pre-flight: #${issue_number} in ${repo_slug} — ${log_tag} → skip (t3050)" >>"$LOGFILE"
	return 0
}

#######################################
# t3050: Scan a parent issue body for #NNN refs and count which ones are
# merged PRs. Echoes "<merged> <total> <merged_list>" on stdout (the
# merged_list is a comma-separated string of #NNN refs, may be empty).
#
# Self-references to the parent issue are excluded so the parent's own
# number doesn't get counted against itself.
#
# Args:
#   $1 - self_num (parent issue number, excluded from refs)
#   $2 - repo_slug (owner/repo)
#   $3 - parent_body (raw text)
#
# Returns: 0 always. Caller parses stdout via awk/cut.
#######################################
_consolidation_count_merged_children() {
	local self_num="$1"
	local repo_slug="$2"
	local parent_body="$3"
	local refs ref merged_at total=0 merged=0 list=""
	refs=$(printf '%s' "$parent_body" \
		| grep -oE '#[0-9]+' \
		| grep -oE '[0-9]+' \
		| grep -v "^${self_num}$" \
		| sort -un 2>/dev/null) || refs=""
	if [[ -z "$refs" ]]; then
		printf '0 0 \n'
		return 0
	fi
	while IFS= read -r ref; do
		[[ -n "$ref" ]] || continue
		total=$((total + 1))
		merged_at=$(gh api "repos/${repo_slug}/pulls/${ref}" \
			--jq '.merged_at // ""' 2>/dev/null) || merged_at=""
		if [[ -n "$merged_at" ]]; then
			merged=$((merged + 1))
			if [[ -z "$list" ]]; then
				list="#${ref}"
			else
				list="${list}, #${ref}"
			fi
		fi
	done <<<"$refs"
	printf '%s %s %s\n' "$merged" "$total" "$list"
	return 0
}

#######################################
# t3050: Pre-flight gate for _dispatch_issue_consolidation. Aborts when the
# parent issue's work is already resolved, BEFORE any cross-runner lock is
# acquired or child created.
#
# Five abort conditions (cheapest-first):
#   1. Parent has `dispatch-blocked:committed-to-main` label (t2955 cache).
#   2. Parent carries terminal completion labels.
#   3. Parent has a structurally linked merged closing PR.
#   4. Parent is CLOSED with stateReason=NOT_PLANNED.
#   5. ≥80% of #NNN refs in the parent body are merged PRs.
#
# Each abort path posts an idempotent <!-- consolidation-skipped --> marker
# via _consolidation_emit_skip. Fail-open: API errors return 1 (proceed).
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#
# Returns:
#   0 — skip: caller MUST abort consolidation for this parent.
#   1 — proceed: no resolved-parent condition detected.
#######################################
_consolidation_skip_if_resolved() {
	local issue_number="$1"
	local repo_slug="$2"
	# t2863: init all multi-var locals at declaration time so set -u is safe.
	local parent_json="" state="" reason="" labels="" body=""
	local closing_pr="" closing_pr_merged_at=""
	local counts="" merged="" total="" list="" pct=""
	parent_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json state,stateReason,labels,body,closedByPullRequestsReferences 2>/dev/null) || parent_json=""
	if [[ -z "$parent_json" ]]; then
		echo "[pulse-wrapper] _consolidation_skip_if_resolved: API error #${issue_number} ${repo_slug} — failing open (t3050)" >>"$LOGFILE"
		return 1
	fi
	state=$(printf '%s' "$parent_json" | jq -r '.state // "OPEN"' 2>/dev/null) || state="OPEN"
	reason=$(printf '%s' "$parent_json" | jq -r '.stateReason // ""' 2>/dev/null) || reason=""
	labels=$(printf '%s' "$parent_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || labels=""
	body=$(printf '%s' "$parent_json" | jq -r '.body // ""' 2>/dev/null) || body=""
	# Gate 1: dispatch-blocked:committed-to-main label (t2955 cache).
	if printf ',%s,' "$labels" | grep -qF ",dispatch-blocked:committed-to-main,"; then
		_consolidation_emit_skip "$issue_number" "$repo_slug" \
			"parent work already committed to main (t2955 cache label)." \
			"dispatch-blocked:committed-to-main"
		return 0
	fi
	# Gate 2: completion labels survive accidental reopen/normalization paths and
	# are sufficient to prevent a solved issue becoming a consolidation task.
	if printf ',%s,' "$labels" | grep -Eq ',(status:done|solved:[^,]+),'; then
		_consolidation_emit_skip "$issue_number" "$repo_slug" \
			"parent carries terminal completion evidence." \
			"terminal completion label"
		return 0
	fi
	# Gate 3: GitHub retains the structural closing relationship after an
	# accidental reopen. Verify the linked PR actually merged before skipping.
	while IFS= read -r closing_pr; do
		[[ "$closing_pr" =~ ^[0-9]+$ ]] || continue
		closing_pr_merged_at=$(gh api "repos/${repo_slug}/pulls/${closing_pr}" \
			--jq '.merged_at // empty' 2>/dev/null) || closing_pr_merged_at=""
		if [[ -n "$closing_pr_merged_at" ]]; then
			_consolidation_emit_skip "$issue_number" "$repo_slug" \
				"parent already resolved by structurally linked merged PR #${closing_pr}." \
				"merged closing PR #${closing_pr}"
			return 0
		fi
	done < <(printf '%s' "$parent_json" | jq -r '.closedByPullRequestsReferences[]?.number' 2>/dev/null)
	# Gate 4: CLOSED with stateReason=NOT_PLANNED.
	if [[ "$state" == "CLOSED" && "$reason" == "NOT_PLANNED" ]]; then
		_consolidation_emit_skip "$issue_number" "$repo_slug" \
			"parent closed as not_planned. If consolidation is genuinely needed, reopen the parent or file a fresh issue." \
			"CLOSED/NOT_PLANNED"
		return 0
	fi
	# Gate 5: ≥80% of #NNN refs in body are merged PRs.
	counts=$(_consolidation_count_merged_children "$issue_number" "$repo_slug" "$body")
	merged=$(printf '%s' "$counts" | awk '{print $1}')
	total=$(printf '%s' "$counts" | awk '{print $2}')
	list=$(printf '%s' "$counts" | cut -d' ' -f3-)
	if [[ "$total" -gt 0 ]]; then
		pct=$(( merged * 100 / total ))
		if [[ "$pct" -ge 80 ]]; then
			_consolidation_emit_skip "$issue_number" "$repo_slug" \
				"${merged} of ${total} child issues resolved via merged PRs (${list})." \
				"${merged}/${total} child PRs merged"
			return 0
		fi
	fi
	return 1
}
