#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# auto-decomposer-scanner.sh — Dispatch workers to decompose stale parent-tasks
#
# Finds `parent-task` labeled issues where the
# `<!-- parent-needs-decomposition -->` nudge has aged without a human
# response. Two thresholds govern when the scanner fires (t2573):
#   - Fresh parents (0 non-nudge comments): ≥SCANNER_FRESH_PARENT_HOURS (default 4h, env PARENT_TASK_NUDGE_SECONDS)
#   - Aged parents (≥1 non-nudge comments): ≥SCANNER_NUDGE_AGE_HOURS (default 4h, env PARENT_TASK_NUDGE_SECONDS)
# For each qualifying parent, files a worker-ready `tier:thinking` issue
# asking the dispatched worker to read the parent, identify phases/components,
# and create child implementation issues.
#
# Why this exists (t2442):
#   Before t2442, `pulse-issue-reconcile.sh` would detect a parent-task
#   with zero children and post an advisory `<!-- parent-needs-decomposition -->`
#   nudge comment — then do nothing. Because `parent-task` blocks
#   dispatch unconditionally (`dispatch-dedup-helper.sh` returns
#   `PARENT_TASK_BLOCKED`), the issue entered a dispatch black hole: no
#   worker could pick it up, no automation would decompose it, and the
#   nudge comment was advisory-only. Six open backlog issues in
#   marcusquinn/aidevops sat in this state by the time t2442 was filed.
#
#   This scanner closes the loop. After 4h of advisory silence, it
#   files a separate `auto-dispatch` issue that the pulse can actually
#   dispatch a worker against — and that worker, NOT the parent's own
#   (blocked) dispatch slot, performs the decomposition.
#
# Idempotency:
#   Dedupes via title match (`Decompose parent-task #NNNN`) AND the
#   `source:auto-decomposer` label. Re-runs are no-ops. Generator
#   marker in body (`<!-- aidevops:generator=auto-decompose parent=NNNN -->`)
#   is available to pre-dispatch validators that want to re-verify the
#   parent still qualifies before spawning a worker.
#
# Worker-is-triager philosophy (GH#18538):
#   The generated issue body includes explicit Outcome A/B/C instructions
#   so the dispatched worker verifies the premise before burning tokens
#   on a decomposition that may already be done, obsolete, or
#   misclassified. Common Outcome A cases: parent already has a
#   `## Children` section posted between scan and dispatch; parent was
#   relabelled; parent is actually a single-unit task the maintainer
#   forgot to remove `parent-task` from.
#
# Usage:
#   auto-decomposer-scanner.sh {scan|dry-run|help} [REPO]
#
# Env:
#   SCANNER_NUDGE_AGE_HOURS       (default 4h)  — minimum nudge age for aged parents (≥1 non-nudge comment); driven by PARENT_TASK_NUDGE_SECONDS
#   SCANNER_FRESH_PARENT_HOURS    (default 4h)  — minimum nudge age for fresh parents (0 non-nudge comments); driven by PARENT_TASK_NUDGE_SECONDS
#   SCANNER_MAX_ISSUES            (default 3)   — cap per-repo decompose issues per run
#   SCANNER_PARENT_LIST_LIMIT     (default 100) — max parent-task issues to list
#   AUTO_DECOMPOSER_INTERVAL      (default 14400) — seconds before re-filing the same parent (4h, was 86400/1d); env PARENT_TASK_REFILE_GATE_SECONDS
#   AUTO_DECOMPOSER_PARENT_STATE  (default ~/.aidevops/logs/auto-decomposer-parent-state.json) — per-parent state file
#
# t2442: https://github.com/marcusquinn/aidevops/issues/20139
# t2573: https://github.com/marcusquinn/aidevops/issues/20242

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# t2949: PARENT_TASK_NUDGE_SECONDS drives both age thresholds (default 4h = 14400s).
# Derive hours from seconds for the scanner's hour-based comparisons.
_PTNUDGE_HOURS="$(( ${PARENT_TASK_NUDGE_SECONDS:-14400} / 3600 ))"
SCANNER_NUDGE_AGE_HOURS="${SCANNER_NUDGE_AGE_HOURS:-${_PTNUDGE_HOURS}}"
SCANNER_FRESH_PARENT_HOURS="${SCANNER_FRESH_PARENT_HOURS:-${_PTNUDGE_HOURS}}"
SCANNER_MAX_ISSUES="${SCANNER_MAX_ISSUES:-3}"
SCANNER_PARENT_LIST_LIMIT="${SCANNER_PARENT_LIST_LIMIT:-100}"
SCANNER_LABEL="source:auto-decomposer"
# Per-parent re-file interval: inherited from pulse-wrapper.sh export or defaulted here.
# t2949: PARENT_TASK_REFILE_GATE_SECONDS controls this (default 4h = 14400s, was 86400s).
AUTO_DECOMPOSER_INTERVAL="${AUTO_DECOMPOSER_INTERVAL:-${PARENT_TASK_REFILE_GATE_SECONDS:-14400}}"
AUTO_DECOMPOSER_PARENT_STATE="${AUTO_DECOMPOSER_PARENT_STATE:-${HOME}/.aidevops/logs/auto-decomposer-parent-state.json}"
# GH#21017: Lookback window for maintainer-activity skip. Skips a parent
# when the parent OR any extracted child has an OWNER/MEMBER comment in
# the last MAINTAINER_ACTIVITY_HOURS — prevents the scanner from
# re-firing on a parent the maintainer is actively steering.
MAINTAINER_ACTIVITY_HOURS="${MAINTAINER_ACTIVITY_HOURS:-48}"
# GH#21017: Cap on children iterated for the maintainer-activity check.
# Bounds API cost on parents that name many sub-issues in prose.
MAINTAINER_ACTIVITY_CHILD_CAP="${MAINTAINER_ACTIVITY_CHILD_CAP:-10}"

log() { echo "[auto-decomposer] $*" >&2; }

# Known review-bot logins — these accounts post mechanical review comments
# (not a human-engagement signal). Extend as needed when new review bots
# are adopted. Retired Gemini remains to classify historical comments correctly.
readonly REVIEW_BOT_LOGINS_JQ_FILTER='["coderabbitai", "coderabbitai[bot]", "sonarcloud[bot]", "sonarqubecloud[bot]", "codacy-production[bot]", "github-actions[bot]", "gemini-code-assist[bot]", "qodo-merge-pro[bot]", "codefactor-io", "socket-security[bot]"]'

# Build the GitHub REST API path for an issue's comments. Centralised so the
# same `repos/<owner>/<repo>/issues/<num>/comments` literal does not appear
# in multiple call sites (string-literal-ratchet compliance).
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - issue number
# Stdout: the API path string.
_issue_comments_api_path() {
	local repo="$1"
	local issue_num="$2"
	printf 'repos/%s/issues/%s/comments' "$repo" "$issue_num"
	return 0
}

# Count comments on an issue that are NOT the <!-- parent-needs-decomposition -->
# nudge AND NOT authored by a known review bot. A count of 0 means the parent is
# "fresh" (only automated nudge comments and bot activity, no human engagement).
# Fresh parents use SCANNER_FRESH_PARENT_HOURS instead of SCANNER_NUDGE_AGE_HOURS
# as the eligibility threshold.
#
# Exit codes:
#   0 — always (caller inspects the printed value)
_count_non_nudge_comments() {
	local repo="$1"
	local issue_num="$2"
	local count api_path
	api_path=$(_issue_comments_api_path "$repo" "$issue_num")
	# Exclude both the nudge marker AND any comment authored by a known
	# review bot. The comparison is against user.login (lowercased) to
	# absorb the "[bot]" suffix variations.
	count=$(gh api --paginate "$api_path" \
		--jq "[.[] | select(
			(.body | contains(\"<!-- parent-needs-decomposition -->\") | not) and
			(.user.login as \$login | ${REVIEW_BOT_LOGINS_JQ_FILTER} | index(\$login) | not)
		)] | length" \
		2>/dev/null || echo "0")
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%s' "$count"
	return 0
}

# Read the epoch at which this parent last had a decompose issue filed.
# Returns "0" if the state file does not exist or the parent is not recorded.
#
# Exit codes:
#   0 — always (caller inspects the printed value)
_read_parent_last_filed() {
	local repo="$1"
	local parent_num="$2"
	local key="${repo}#${parent_num}"
	if [[ ! -f "$AUTO_DECOMPOSER_PARENT_STATE" ]]; then
		printf '0'
		return 0
	fi
	local epoch
	epoch=$(jq -r --arg k "$key" '.[$k] // 0' "$AUTO_DECOMPOSER_PARENT_STATE" 2>/dev/null || echo "0")
	[[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
	printf '%s' "$epoch"
	return 0
}

# Update the per-parent state file atomically (write-then-rename).
# The state file is a JSON object mapping "<slug>#<issue>" to last-filed epoch.
#
# Exit codes:
#   0 — always
_update_parent_state() {
	local repo="$1"
	local parent_num="$2"
	local epoch="$3"
	local key="${repo}#${parent_num}"
	local state_dir
	state_dir=$(dirname "$AUTO_DECOMPOSER_PARENT_STATE")
	mkdir -p "$state_dir" 2>/dev/null || true
	local existing="{}"
	if [[ -f "$AUTO_DECOMPOSER_PARENT_STATE" ]]; then
		existing=$(cat "$AUTO_DECOMPOSER_PARENT_STATE" 2>/dev/null || echo "{}")
		[[ "$existing" =~ ^\{ ]] || existing="{}"
	fi
	local tmp
	tmp=$(mktemp "${state_dir}/.auto-decomposer-state.XXXXXX")
	printf '%s' "$existing" | jq --arg k "$key" --argjson v "$epoch" '.[$k] = $v' >"$tmp" 2>/dev/null || {
		rm -f "$tmp"
		return 0
	}
	mv "$tmp" "$AUTO_DECOMPOSER_PARENT_STATE"
	return 0
}

# Compute the age in hours of the first `<!-- parent-needs-decomposition -->`
# nudge comment on a parent issue. Prints the age on stdout (empty string
# if no nudge found, or on date-parse failure). Uses GNU date on Linux
# and BSD date on macOS via feature detection.
#
# Exit codes:
#   0 — always (caller inspects the printed value)
_nudge_age_hours() {
	local repo="$1"
	local issue_num="$2"
	local created_at api_path
	api_path=$(_issue_comments_api_path "$repo" "$issue_num")
	created_at=$(gh api --paginate "$api_path" \
		--jq '[.[] | select(.body | contains("<!-- parent-needs-decomposition -->")) | .created_at] | first // ""' \
		|| echo "")
	if [[ -z "$created_at" ]]; then
		printf ''
		return 0
	fi
	local created_epoch=""
	if date --version >/dev/null 2>&1; then
		created_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo "")
	else
		created_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || echo "")
	fi
	if [[ -z "$created_epoch" ]]; then
		log "parent #${issue_num}: cannot parse nudge timestamp '${created_at}'"
		printf ''
		return 0
	fi
	local now_epoch
	now_epoch=$(date +%s)
	printf '%s' "$(((now_epoch - created_epoch) / 3600))"
	return 0
}

# GH#21017: Check whether a parent body declares decomposition.
#
# Mirrors `_parent_body_has_phase_markers` in `issue-sync-lib.sh:701` —
# kept inline to avoid sourcing the 1645-line library on every pulse
# cycle. Both functions MUST stay in regex-sync; if you change the
# pattern in one, update the other and the canonical definition in
# `pulse-issue-reconcile.sh::_extract_children_section`.
#
# A body is considered "decomposition-ready" if it contains any of:
#   - `## Children` / `## Child issues` / `## Sub-tasks` heading
#   - `## Phase` / `## Phases` heading
#   - Narrow prose patterns: `Phase N #NNNN`, `filed as #NNNN`,
#     `tracks #NNNN`, `blocked by #NNNN` (matches
#     `_extract_children_from_prose`)
#
# This is the primary fix for the canonical failure case (a maintainer
# decomposed a parent between scan and re-scan, but the scanner re-fired
# because it never read the parent body).
#
# Arguments:
#   $1 - parent issue body text (may be empty)
# Returns: 0 if at least one marker present, 1 otherwise.
_body_has_decomposition_markers() {
	local body="$1"
	[[ -n "$body" ]] || return 1

	# H2 heading match — must mirror issue-sync-lib.sh:709 byte-for-byte.
	if printf '%s' "$body" | grep -qE '^##[[:space:]]+(Children|Child [Ii]ssues|Sub-?[Tt]asks|Phases?([[:space:]]+.*)?)[[:space:]]*$' 2>/dev/null; then
		return 0
	fi

	# Prose patterns — must mirror issue-sync-lib.sh:715 byte-for-byte.
	if printf '%s' "$body" | grep -qE '(^|[^a-zA-Z0-9_])([Pp]hase[[:space:]]+[0-9]+[^#]*#[0-9]+|[Ff]iled[[:space:]]+as[[:space:]]*#[0-9]+|[Tt]racks[[:space:]]+#[0-9]+|[Bb]locked[[:space:]]-?[[:space:]]*by[[:space:]]*:?[[:space:]]*#[0-9]+)' 2>/dev/null; then
		return 0
	fi

	return 1
}

# GH#21017: Extract child issue numbers from a parent body using the
# same prose patterns `_extract_children_from_prose` honours.
#
# DELIBERATELY narrow — see `pulse-issue-reconcile.sh:1017` for the
# rationale (bare `#NNN` mentions caused premature parent close in
# t2244/#19734). We accept the same four phrase shapes:
#
#   1. `Phase N <anything> #NNNN`
#   2. `filed as #NNNN`
#   3. `tracks #NNNN`
#   4. `[Bb]locked by:? #NNNN`
#
# Output: one child issue number per line, deduplicated. Empty output
# means "no children declared in prose" — caller must NOT treat as
# "no children exist", only as "we cannot enumerate from the body".
#
# Arguments:
#   $1 - parent issue body text
# Returns: always 0.
_extract_children_from_body() {
	local body="$1"
	[[ -n "$body" ]] || return 0

	# Match patterns then extract the bare numeric token. Anchors prevent
	# in-word matches (e.g. "hashtracks" or "#Nfiled").
	printf '%s' "$body" | grep -oE '(^|[^a-zA-Z0-9_])([Pp]hase[[:space:]]+[0-9]+[^#]*#[0-9]+|[Ff]iled[[:space:]]+as[[:space:]]*#[0-9]+|[Tt]racks[[:space:]]+#[0-9]+|[Bb]locked[[:space:]]-?[[:space:]]*by[[:space:]]*:?[[:space:]]*#[0-9]+)' 2>/dev/null \
		| grep -oE '#[0-9]+' \
		| tr -d '#' \
		| sort -u
	return 0
}

# Return 0 when the parent body has a ## Phases plan but no concrete child
# references. These parents are not "decomposed" yet; parent reconciliation
# should bootstrap the first phase child via shared-phase-filing.sh.
_body_has_phase_plan_without_children() {
	local body="$1"
	[[ -n "$body" ]] || return 1
	printf '%s' "$body" | grep -qE '^##[[:space:]]+Phases?([[:space:]]+.*)?[[:space:]]*$' 2>/dev/null || return 1
	[[ -z "$(_extract_children_from_body "$body")" ]] || return 1
	return 0
}

# GH#21017: Return 0 if the issue has at least one OWNER/MEMBER comment
# created after the supplied ISO-8601 cutoff timestamp, EXCLUDING
# framework-automated comments (nudge, ops, provenance markers).
#
# OWNER/MEMBER scope is intentional — it captures maintainer steering
# without including drive-by COLLABORATOR or external-contributor
# comments (which can be high-volume on busy issues without representing
# a real "the maintainer is engaged" signal).
#
# Framework-automated comment exclusion matches the existing contract
# of `_count_non_nudge_comments` (which filters the nudge marker and
# review bots). Filtered markers — these are HTML comments emitted by
# framework helpers running under the maintainer's gh auth, NOT actual
# human comments:
#   - `<!-- parent-needs-decomposition -->` (decomposition nudge)
#   - `<!-- ops:start -->`                  (dispatch / kill / triage)
#   - `<!-- provenance:start -->`           (auto-generated bodies)
#   - `<!-- aidevops:generator=`            (any auto-decompose / scanner output)
# Comments carrying ONLY the `<!-- aidevops:sig -->` signature footer
# remain counted — the body itself is still maintainer authorship via
# a framework wrapper (e.g. `gh_issue_comment`).
#
# Fail-open on API errors (returns 1) so a transient `gh api` failure
# never silently expands scanner activity. The dispatch decision is
# already conservative — the worst case of a missed maintainer comment
# is one extra worker dispatch the maintainer can close as Outcome A.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - issue number
#   $3 - cutoff timestamp (ISO-8601 UTC, e.g. 2026-04-24T12:00:00Z)
# Returns: 0 if recent maintainer comment found, 1 otherwise.
_has_recent_maintainer_comment() {
	local repo="$1"
	local issue_num="$2"
	local cutoff_iso="$3"

	[[ -n "$repo" && "$issue_num" =~ ^[0-9]+$ && -n "$cutoff_iso" ]] || return 1

	local count api_path
	api_path=$(_issue_comments_api_path "$repo" "$issue_num")
	count=$(gh api --method GET --paginate "$api_path" -f since="$cutoff_iso" \
		--jq "[.[] | select(.created_at > \"${cutoff_iso}\")
			| select(.author_association == \"OWNER\" or .author_association == \"MEMBER\")
			| select(.body | contains(\"<!-- parent-needs-decomposition -->\") | not)
			| select(.body | contains(\"<!-- ops:start -->\") | not)
			| select(.body | contains(\"<!-- provenance:start -->\") | not)
			| select(.body | contains(\"<!-- aidevops:generator=\") | not)
		] | length" \
		2>/dev/null || echo "0")
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	if [[ "$count" -gt 0 ]]; then
		return 0
	fi
	return 1
}

# GH#21017: Compute the ISO-8601 UTC timestamp `lookback_hours` ago.
# Uses GNU date on Linux and BSD date on macOS via feature detection.
# Prints empty string on parse failure (caller should treat as
# "cannot compute cutoff" and fail-open).
#
# Arguments:
#   $1 - lookback hours (positive integer)
_iso_cutoff_hours_ago() {
	local lookback_hours="$1"
	[[ "$lookback_hours" =~ ^[1-9][0-9]*$ ]] || {
		printf ''
		return 0
	}
	local cutoff=""
	if date --version >/dev/null 2>&1; then
		cutoff=$(date -u -d "${lookback_hours} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
	else
		cutoff=$(date -u -v "-${lookback_hours}H" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
	fi
	printf '%s' "$cutoff"
	return 0
}

# Return 0 if a decompose issue already exists for this parent (any
# state — open, closed, merged, superseded). We dedupe across all states
# so that a closed "premise falsified" Outcome A never triggers another
# dispatch; re-escalation requires the maintainer to delete the closed
# issue.
_decompose_issue_exists() {
	local repo="$1"
	local parent_num="$2"
	# Titles are "Decompose parent-task #NNN: <title>" — include the colon
	# so startswith("#1234:") cannot false-positive-match "#12345:". Filter
	# client-side via jq --arg to avoid shell interpolation in the filter
	# expression. --paginate retrieves all dedup-labelled issues regardless
	# of count; stderr is not suppressed so jq errors surface in logs.
	local title_prefix="Decompose parent-task #${parent_num}:"
	local count
	count=$(gh issue list --repo "$repo" --label "$SCANNER_LABEL" \
		--state all --limit 1000 \
		--json title \
		| jq --arg prefix "$title_prefix" \
			'[.[] | select(.title | startswith($prefix))] | length' \
		|| echo "0")
	[[ "$count" =~ ^[1-9][0-9]*$ ]]
}

# Render the worker-ready decompose issue body. The body includes 5 of
# the 7 t2417 heading signals (What / Why / How / Acceptance / Session
# Origin) so the pre-flight brief-readiness check treats it as worker-
# ready and skips the separate brief file. Generator marker is inline
# so pre-dispatch validators can reverify the premise without parsing
# the title.
_build_decompose_body() {
	local repo="$1"
	local parent_num="$2"
	local parent_title="$3"
	cat <<MD
<!-- aidevops:generator=auto-decompose parent=${parent_num} -->

## What

Decompose parent-task [#${parent_num}](https://github.com/${repo}/issues/${parent_num}) — _${parent_title}_ — into child implementation issues.

## Why

Parent-task #${parent_num} has carried the \`parent-task\` label for
≥${SCANNER_NUDGE_AGE_HOURS}h since \`pulse-issue-reconcile.sh\` posted its
\`<!-- parent-needs-decomposition -->\` nudge. Without child issues the
parent is a dispatch black hole: the \`parent-task\` label blocks
dispatch unconditionally in \`dispatch-dedup-helper.sh\` (\`PARENT_TASK_BLOCKED\`),
but the nudge comment is advisory-only — no automation actually
decomposes the parent.

This issue closes that loop. Implementing it clears the block on
#${parent_num} by replacing it with tracked children.

## How

1. **Read the parent issue** at https://github.com/${repo}/issues/${parent_num}
   and identify logical phases, components, or sub-tasks. Look for
   explicit \`## Phase\` sections, bullet lists of work items, or
   natural seams in the narrative.
2. **For each child:** claim a fresh task ID via \`claim-task-id.sh\`.
   Include \`ref:GH#${parent_num}\` in the TODO entry so the hierarchy
   is traceable. Use \`#auto-dispatch\` unless the child genuinely
   needs credentials or further decomposition of its own.
3. **Edit parent #${parent_num}'s body** to add a \`## Children\` section
   listing each child as \`- #<NNNN> — <short description>\`. This
   lets \`reconcile_completed_parent_tasks\` detect completion and
   close the parent automatically once all children merge.
4. **If the parent is genuinely single-unit** (cannot be split, or its
   scope has changed so it no longer needs a parent), close THIS
   issue with an Outcome A rationale comment explaining why, and
   remove the \`parent-task\` label from #${parent_num} so it can
   dispatch normally.

## Acceptance

- Parent #${parent_num} has a \`## Children\` section listing ≥2 children, OR
- Parent #${parent_num} is closed / relabelled with a rationale, OR
- THIS issue is closed with an Outcome A rationale (parent should not have been a parent).

## Session Origin

Auto-generated by \`.agents/scripts/auto-decomposer-scanner.sh\` (t2442).
Dispatched after parent #${parent_num}'s \`<!-- parent-needs-decomposition -->\`
nudge aged ≥${SCANNER_NUDGE_AGE_HOURS}h without a human response.

---

### You are the triager (worker-is-triager rule)

This issue is auto-created. **Verify the premise before acting** — the
parent may have been decomposed by another session between scan and
dispatch. Read the CURRENT state of #${parent_num} first, not the state
that existed when this issue was filed.

- **Outcome A — premise falsified → close THIS issue.** If #${parent_num}
  now has a \`## Children\` section, linked child PRs/issues with
  \`Resolves #${parent_num}\` / \`Ref #${parent_num}\` / \`For #${parent_num}\`,
  explicit \`## Phase N\` refs, or has been closed/relabelled,
  close THIS issue with the counter-evidence. No PR needed.
- **Outcome B — premise correct → implement.** Follow the \`## How\`
  steps above. Open any code PRs with \`Ref #${parent_num}\` or
  \`For #${parent_num}\` (parent stays open until children merge, per
  the t2046 parent-task PR keyword rule). For THIS follow-up issue
  itself, use \`Resolves #<this-issue-number>\` so the merge pass
  closes it cleanly.
- **Outcome C — genuine judgment call.** Only if the decomposition
  requires an architectural / policy / breaking-change decision you
  cannot resolve autonomously: post a decision comment with
  **Premise check**, **Analysis**, **Recommended path**, and
  **Specific question**, then apply \`hold-for-review\`.
  Ambiguity about scope or style is NOT Outcome C.
MD
	return 0
}

# Create the decompose issue via gh_create_issue. Honours dry-run by
# logging intent without side effects.
_create_decompose_issue() {
	local repo="$1"
	local parent_num="$2"
	local parent_title="$3"
	local dry_run="$4"
	local title="Decompose parent-task #${parent_num}: ${parent_title}"
	local body
	body=$(_build_decompose_body "$repo" "$parent_num" "$parent_title")

	if [[ "$dry_run" == true ]]; then
		log "[DRY-RUN] Would create: ${title}"
		log "[DRY-RUN] Body length: ${#body} chars"
		return 0
	fi

	local sig_helper="${SCRIPT_DIR}/gh-signature-helper.sh"
	local sig=""
	[[ -x "$sig_helper" ]] && sig=$("$sig_helper" footer 2>/dev/null || echo "")

	# Ensure the dedup label exists (idempotent). --force keeps colour /
	# description in sync with the scanner's source of truth.
	gh label create "$SCANNER_LABEL" --repo "$repo" \
		--description "Auto-created by auto-decomposer-scanner.sh (t2442)" \
		--color "C2E0C6" --force >/dev/null 2>&1 || true

	# GH#18670 (Fix 7) parity: hardcode origin:worker as defence in depth
	# against pulse-wrapper.sh missing export of AIDEVOPS_HEADLESS=true
	# or against manual invocation from a dev shell.
	gh_create_issue --repo "$repo" --title "$title" \
		--label "auto-dispatch,tier:thinking,${SCANNER_LABEL},origin:worker" \
		--body "${body}${sig}"
	return 0
}

# GH#21017: Evaluate the two new skip gates against a parent and report
# the reason on stdout. Designed as a single helper so do_scan can stay
# under the 100-line function-complexity gate while still expressing
# the full check inline-readable in this file.
#
# Logic:
#   1. If parent body declares phase-only decomposition with zero filed refs,
#      emit "phase-plan-awaiting-reconcile" (the reconcile pass bootstraps it).
#   2. If parent body declares decomposition (## Children/Phase/prose
#      ref), emit "has-children".
#   3. Otherwise, if the parent OR any extracted child has an
#      OWNER/MEMBER comment in the last MAINTAINER_ACTIVITY_HOURS
#      (capped by MAINTAINER_ACTIVITY_CHILD_CAP for the children
#      sweep), emit "maintainer-activity".
#   4. Otherwise, emit "" (caller proceeds with existing nudge-age
#      gate).
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - parent issue number
#   $3 - parent body (already fetched once by the caller)
# Stdout: "phase-plan-awaiting-reconcile" | "has-children" | "maintainer-activity" | ""
# Returns: 0 always (caller inspects the printed value).
_evaluate_gh21017_skip_reason() {
	local repo="$1"
	local parent_num="$2"
	local parent_body="$3"

	if _body_has_phase_plan_without_children "$parent_body"; then
		printf 'phase-plan-awaiting-reconcile'
		return 0
	fi

	if _body_has_decomposition_markers "$parent_body"; then
		printf 'has-children'
		return 0
	fi

	local maintainer_cutoff
	maintainer_cutoff=$(_iso_cutoff_hours_ago "$MAINTAINER_ACTIVITY_HOURS")
	if [[ -z "$maintainer_cutoff" ]]; then
		printf ''
		return 0
	fi

	if _has_recent_maintainer_comment "$repo" "$parent_num" "$maintainer_cutoff"; then
		printf 'maintainer-activity'
		return 0
	fi

	local child_count=0 child
	while IFS= read -r child; do
		[[ -z "$child" || "$child" == "$parent_num" ]] && continue
		child_count=$((child_count + 1))
		if [[ "$child_count" -gt "$MAINTAINER_ACTIVITY_CHILD_CAP" ]]; then
			break
		fi
		if _has_recent_maintainer_comment "$repo" "$child" "$maintainer_cutoff"; then
			printf 'maintainer-activity'
			return 0
		fi
	done < <(_extract_children_from_body "$parent_body")

	printf ''
	return 0
}

do_scan() {
	local repo="$1"
	local dry_run="$2"
	log "Scanning ${repo} for stale parent-tasks (fresh: ≥${SCANNER_FRESH_PARENT_HOURS}h, aged: ≥${SCANNER_NUDGE_AGE_HOURS}h)"

	local parents_json
	parents_json=$(gh issue list --repo "$repo" --label "parent-task" \
		--state open --limit "$SCANNER_PARENT_LIST_LIMIT" \
		--json number,title 2>/dev/null || echo "[]")
	if [[ "$parents_json" == "[]" ]]; then
		log "No open parent-task issues in ${repo}"
		return 0
	fi

	local now_epoch
	now_epoch=$(date +%s)

	local issues_created=0 total_seen=0 skipped_no_nudge=0 skipped_too_young=0 skipped_existing=0 skipped_refiled=0
	# GH#21017: counters for the new skip paths.
	local skipped_has_children=0 skipped_maintainer_activity=0 skipped_phase_reconcile=0
	while IFS=$'\t' read -r parent_num parent_title; do
		[[ -z "$parent_num" ]] && continue
		total_seen=$((total_seen + 1))
		if [[ "$issues_created" -ge "$SCANNER_MAX_ISSUES" ]]; then
			log "Max decompose issues per run reached (${SCANNER_MAX_ISSUES})"
			break
		fi

		if _decompose_issue_exists "$repo" "$parent_num"; then
			log "parent #${parent_num}: decompose issue already exists, skip"
			skipped_existing=$((skipped_existing + 1))
			continue
		fi

		# Per-parent re-file gate: skip if filed within AUTO_DECOMPOSER_INTERVAL.
		local last_filed
		last_filed=$(_read_parent_last_filed "$repo" "$parent_num")
		if [[ "$last_filed" -gt 0 ]]; then
			local elapsed_since_filed=$(( now_epoch - last_filed ))
			if [[ "$elapsed_since_filed" -lt "$AUTO_DECOMPOSER_INTERVAL" ]]; then
				local days_remaining=$(( (AUTO_DECOMPOSER_INTERVAL - elapsed_since_filed) / 86400 ))
				log "parent #${parent_num}: re-file suppressed (filed $((elapsed_since_filed / 86400))d ago, gate ${days_remaining}d remaining)"
				skipped_refiled=$((skipped_refiled + 1))
				continue
			fi
		fi

		# GH#21017: Skip on body decomposition markers or recent maintainer
		# activity. Helper returns "" on fetch failure → fall through to
		# the existing nudge-age gate.
		local parent_body skip_reason
		parent_body=$(gh api "repos/${repo}/issues/${parent_num}" --jq '.body // ""' 2>/dev/null || echo "")
		skip_reason=$(_evaluate_gh21017_skip_reason "$repo" "$parent_num" "$parent_body")
		case "$skip_reason" in
			phase-plan-awaiting-reconcile) log "[skip:phase-plan-awaiting-reconcile] parent #${parent_num}: ## Phases has zero child refs; parent reconcile will bootstrap the next phase child"; skipped_phase_reconcile=$((skipped_phase_reconcile + 1)); continue ;;
			has-children) log "[skip:has-children] parent #${parent_num}: body declares decomposition (## Children/Phase/prose ref)"; skipped_has_children=$((skipped_has_children + 1)); continue ;;
			maintainer-activity) log "[skip:recent-maintainer-activity] parent #${parent_num}: OWNER/MEMBER comment in last ${MAINTAINER_ACTIVITY_HOURS}h on parent or child"; skipped_maintainer_activity=$((skipped_maintainer_activity + 1)); continue ;;
		esac

		local hours
		hours=$(_nudge_age_hours "$repo" "$parent_num")
		if [[ -z "$hours" ]]; then
			log "parent #${parent_num}: no decomposition nudge yet, skip"
			skipped_no_nudge=$((skipped_no_nudge + 1))
			continue
		fi

		# Determine eligibility threshold based on whether the parent is fresh.
		# A fresh parent has 0 non-nudge comments — no human or other-bot activity
		# beyond the automated nudge. Fresh parents get a shorter threshold (6h
		# default) because waiting 24h on a pristine issue is unnecessarily slow.
		local non_nudge_count
		non_nudge_count=$(_count_non_nudge_comments "$repo" "$parent_num")
		local threshold="$SCANNER_NUDGE_AGE_HOURS"
		local parent_kind="aged"
		if [[ "$non_nudge_count" -eq 0 ]]; then
			threshold="$SCANNER_FRESH_PARENT_HOURS"
			parent_kind="fresh"
		fi

		if [[ "$hours" -lt "$threshold" ]]; then
			log "parent #${parent_num}: ${parent_kind} nudge ${hours}h old (threshold ${threshold}h), skip"
			skipped_too_young=$((skipped_too_young + 1))
			continue
		fi

		log "parent #${parent_num}: ${parent_kind} nudge ${hours}h old (threshold ${threshold}h), filing decompose issue"
		_create_decompose_issue "$repo" "$parent_num" "$parent_title" "$dry_run"
		issues_created=$((issues_created + 1))

		# Record the filing time in the per-parent state file (skip for dry-run).
		if [[ "$dry_run" != true ]]; then
			_update_parent_state "$repo" "$parent_num" "$now_epoch"
		fi
	done < <(printf '%s' "$parents_json" | jq -r '.[] | "\(.number)\t\(.title)"')

	log "Scan done. Parents seen: ${total_seen}, created: ${issues_created}, skipped(existing): ${skipped_existing}, skipped(no-nudge): ${skipped_no_nudge}, skipped(too-young): ${skipped_too_young}, skipped(re-file gate): ${skipped_refiled}, skipped(phase-reconcile): ${skipped_phase_reconcile}, skipped(has-children): ${skipped_has_children}, skipped(maintainer-activity): ${skipped_maintainer_activity}"
	return 0
}

main() {
	local command="${1:-}"
	local repo="${2:-}"
	if [[ -z "$command" ]]; then
		echo "Usage: $(basename "$0") {scan|dry-run|help} [REPO]" >&2
		return 2
	fi
	if [[ -z "$repo" ]] && [[ "$command" != "help" && "$command" != "-h" && "$command" != "--help" ]]; then
		repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
		if [[ -z "$repo" ]]; then
			echo "ERROR: Cannot determine repo (not in a gh-tracked checkout and no REPO arg)" >&2
			return 1
		fi
	fi
	case "$command" in
	scan) do_scan "$repo" false ;;
	dry-run) do_scan "$repo" true ;;
	-h | --help | help)
		cat <<EOF
Usage: $(basename "$0") {scan|dry-run|help} [REPO]

  scan      Scan open parent-task issues; file worker-ready decompose
            issues for parents whose nudge has aged past the threshold.
            Dedupes via title + source:auto-decomposer label. Per-parent
            state prevents re-filing the same parent within 4h (AUTO_DECOMPOSER_INTERVAL).
  dry-run   Same as scan but logs what would be created (no state writes).
  help      This message.

Env vars:
  SCANNER_NUDGE_AGE_HOURS         (default 4)       Minimum nudge age (hours) for aged parents (≥1 non-nudge comment); driven by PARENT_TASK_NUDGE_SECONDS
  SCANNER_FRESH_PARENT_HOURS      (default 4)       Minimum nudge age (hours) for fresh parents (0 non-nudge comments); driven by PARENT_TASK_NUDGE_SECONDS
  SCANNER_MAX_ISSUES              (default 3)       Cap per-repo decompose issues per run
  SCANNER_PARENT_LIST_LIMIT       (default 100)     Max parent-task issues to list
  AUTO_DECOMPOSER_INTERVAL        (default 14400)   Seconds before re-filing the same parent (4h); env PARENT_TASK_REFILE_GATE_SECONDS
  AUTO_DECOMPOSER_PARENT_STATE                      Path to per-parent state file (JSON)
  MAINTAINER_ACTIVITY_HOURS       (default 48)      Lookback window for OWNER/MEMBER comment skip (GH#21017)
  MAINTAINER_ACTIVITY_CHILD_CAP   (default 10)      Max children iterated for maintainer-activity check (GH#21017)

t2442: closes the parent-task dispatch black hole.
t2573: per-parent gating, fresh-parent threshold, no global run gate.
GH#20532: zero-delay thresholds + 1-day re-file for AI-throughput mode (t2949: now 4h).
GH#21017: skip decomposed parents + skip during recent maintainer activity.
EOF
		;;
	*)
		echo "ERROR: Unknown command '$command'" >&2
		return 2
		;;
	esac
	return 0
}

# Source guard: only run main() when executed as a script, not when
# sourced by the test harness.
(return 0 2>/dev/null) || main "$@"
