#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# circuit-breaker-meta-filer.sh — File root-cause meta-issues when per-issue
# circuit breakers (t2007 cost, t2769 no_work) trip (t3076).
#
# Background:
#   The existing breakers halt dispatch with status:blocked. This helper turns
#   each trip into a self-healing
#   cycle:
#
#     breaker fires → forensics gathered → meta-issue filed with hypothesis
#     → worker dispatched on meta-issue → fix lands → original unblocks
#
#   Original gets `blocked-by:#<meta>` + a marker comment on the original
#   recording the meta-issue number. Idempotent — second trip on the same
#   original does NOT file a duplicate meta-issue.
#
# Subcommands:
#   file       File a meta-issue for a tripped circuit breaker.
#   help       Show usage.
#
# Environment:
#   AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE  if "1", the file subcommand
#                                               is a no-op (emergency bypass).
#   AIDEVOPS_CIRCUIT_BREAKER_META_LABELS        override labels applied to
#                                               the meta-issue (comma-separated).
#                                               Default:
#                                                 auto-dispatch,tier:thinking,
#                                                 bug,pulse,
#                                                 framework,circuit-breaker-meta
#   AIDEVOPS_CIRCUIT_BREAKER_META_TARGET_REPO   force the repo where the
#                                               meta-issue is filed. By default,
#                                               public repos without framework
#                                               script sources route to the
#                                               framework source repo so workers
#                                               land in a repo containing the
#                                               files named by the brief.
#   AIDEVOPS_CIRCUIT_BREAKER_META_FRAMEWORK_REPO
#                                               framework source repo fallback.
#                                               Default: marcusquinn/aidevops.
#   AIDEVOPS_CIRCUIT_BREAKER_META_FORENSIC_LINES
#                                               max log lines included in the
#                                               body. Default 50.
#   PULSE_LOG                                   pulse log path (default
#                                               ~/.aidevops/logs/pulse.log).
#   DISPATCH_STAGES_TSV                         dispatch stages file (default
#                                               ~/.aidevops/logs/dispatch-stages.tsv).
#
# Exit codes:
#   0 = meta-issue created OR idempotent skip OR disabled (bypass)
#   1 = invalid args / missing required field
#   2 = gh API failure
#
# Wired by:
#   - worker-lifecycle-common.sh   (t2769 no_work breaker trip)
#   - dispatch-dedup-cost.sh       (t2007 cost breaker trip)
#
# Released by:
#   - pulse-merge.sh               (when meta-PR merges, removes blocked-by
#                                  on the original; restores status:available
#                                  if no other blockers remain)

set -uo pipefail

# Resolve SCRIPT_DIR for both direct execution and sourcing.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# shellcheck source=./shared-gh-wrappers.sh
source "${SCRIPT_DIR}/shared-gh-wrappers.sh"

readonly _CB_META_MARKER='circuit-breaker-meta-filed'
readonly _CB_META_DEFAULT_LABELS='auto-dispatch,tier:thinking,bug,pulse,framework,circuit-breaker-meta'
readonly _CB_BREAKER_COST='cost'
readonly _CB_BREAKER_NO_WORK='no_work'
readonly _CB_LABEL_COST='t2007 cost'
readonly _CB_LABEL_NO_WORK='t2769 no_work'
readonly _CB_DEFAULT_FRAMEWORK_REPO='marcusquinn/aidevops'

#######################################
# Return the blocked-by label that links an original issue to its meta-issue.
# Same-repo links keep the legacy short label; cross-repo links include the
# meta repo so unblock-on-merge can remove the exact label later.
# Args: $1=original_repo, $2=meta_repo, $3=meta_number
# Stdout: label
# Returns: 0 always
#######################################
_cb_meta_blocked_label() {
	local original_repo="$1"
	local meta_repo="$2"
	local meta_number="$3"

	if [[ "$original_repo" == "$meta_repo" ]]; then
		printf 'blocked-by:#%s' "$meta_number"
	else
		printf 'blocked-by:%s#%s' "$meta_repo" "$meta_number"
	fi
	return 0
}

#######################################
# Does the repo contain the framework source script named in generated briefs?
# Args: $1=repo_slug
# Returns: 0 if present, 1 otherwise
#######################################
_cb_meta_repo_has_framework_sources() {
	local repo_slug="$1"

	if gh api "repos/${repo_slug}/contents/.agents/scripts/circuit-breaker-meta-filer.sh" \
		>/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# Is the original repo private? Fail closed on API errors to avoid leaking
# private repo names into a public framework issue.
# Args: $1=repo_slug
# Returns: 0 if private/unknown, 1 if public
#######################################
_cb_meta_repo_is_private_or_unknown() {
	local repo_slug="$1"
	local is_private=""

	is_private=$(gh api "repos/${repo_slug}" --jq '.private // true' 2>/dev/null) || return 0
	if [[ "$is_private" == "true" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Choose where to file the meta-issue.
#
# Root cause fixed for example-repo#4003: framework breaker meta-issues were filed
# into application repos that do not contain aidevops framework scripts, so the
# dispatched worker had no target files to edit and exited clean/no-work. Public
# repos that lack the framework source route to the framework repo by default;
# private/unknown repos stay local to avoid leaking private repo names.
# Args: $1=original_repo
# Stdout: target repo slug
# Returns: 0 always
#######################################
_cb_meta_target_repo() {
	local original_repo="$1"

	if [[ -n "${AIDEVOPS_CIRCUIT_BREAKER_META_TARGET_REPO:-}" ]]; then
		printf '%s' "$AIDEVOPS_CIRCUIT_BREAKER_META_TARGET_REPO"
		return 0
	fi

	if _cb_meta_repo_has_framework_sources "$original_repo"; then
		printf '%s' "$original_repo"
		return 0
	fi

	if _cb_meta_repo_is_private_or_unknown "$original_repo"; then
		printf '%s' "$original_repo"
		return 0
	fi

	printf '%s' "${AIDEVOPS_CIRCUIT_BREAKER_META_FRAMEWORK_REPO:-$_CB_DEFAULT_FRAMEWORK_REPO}"
	return 0
}

#######################################
# Idempotency check: has a meta-issue marker already been recorded
# on this issue? Returns the existing meta-issue ref on stdout
# when found, empty otherwise.
#
# Marker format on the original issue (in a comment body):
#   <!-- circuit-breaker-meta-filed:#<NNN> -->
#   <!-- circuit-breaker-meta-filed:<owner>/<repo>#<NNN> -->
#
# Args: $1=issue_number, $2=repo_slug
# Stdout: existing meta-issue ref (owner/repo#number), or empty
# Returns: 0 always (best-effort)
#######################################
_cb_meta_existing() {
	local issue_number="$1"
	local repo_slug="$2"
	local marker_re
	marker_re='<!-- '"${_CB_META_MARKER}"':([^[:space:]#]+/[^[:space:]#]+)?#[0-9]+ -->'

	local comments
	comments=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" --paginate 2>/dev/null) || comments=""
	if [[ -z "$comments" || "$comments" == "null" ]]; then
		return 0
	fi

	local hit
	hit=$(printf '%s' "$comments" |
		jq -r '.[].body // ""' 2>/dev/null |
		grep -oE "$marker_re" |
		head -1 || true)
	[[ -n "$hit" ]] || return 0

	local marker_value
	marker_value="${hit#*"${_CB_META_MARKER}":}"
	marker_value="${marker_value% -->}"
	if [[ "$marker_value" == \#* ]]; then
		printf '%s%s' "$repo_slug" "$marker_value"
	else
		printf '%s' "$marker_value"
	fi
	return 0
}

#######################################
# Gather pulse log lines mentioning the issue.
# Args: $1=issue_number, $2=max_lines
# Stdout: log slice (may be empty)
#######################################
_cb_meta_log_slice() {
	local issue_number="$1"
	local max_lines="${2:-50}"
	local pulse_log="${PULSE_LOG:-${HOME}/.aidevops/logs/pulse.log}"

	[[ -r "$pulse_log" ]] || return 0

	# Match either "#21840" or " 21840" (TSV-style) — bound match to
	# avoid spurious matches on "#218400" by using grep -wE.
	grep -E "(^|[^0-9])#?${issue_number}([^0-9]|$)" "$pulse_log" 2>/dev/null |
		tail -n "$max_lines" || true
	return 0
}

#######################################
# Gather dispatch-stages.tsv lines for the issue.
# Args: $1=issue_number
# Stdout: TSV slice (may be empty)
#######################################
_cb_meta_stages_slice() {
	local issue_number="$1"
	local stages_tsv="${DISPATCH_STAGES_TSV:-${HOME}/.aidevops/logs/dispatch-stages.tsv}"

	[[ -r "$stages_tsv" ]] || return 0

	# TSV columns: timestamp, issue_ref, repo_slug, stage, ms
	grep -E $'\t#?'"${issue_number}"$'\t' "$stages_tsv" 2>/dev/null |
		tail -50 || true
	return 0
}

#######################################
# Compose the meta-issue body. t1900-compliant — includes Files Scope and
# verification steps so the worker dispatched against the meta-issue can
# act without re-discovering context.
#
# Args:
#   $1=issue_number  (original issue)
#   $2=repo_slug
#   $3=breaker_type  (cost|no_work)
#   $4=failure_count
#   $5=reason        (free-text, may be empty)
#   $6=tier          (used by cost breaker; may be empty)
#   $7=spent_tokens  (used by cost breaker; may be empty)
#   $8=budget_tokens (used by cost breaker; may be empty)
#######################################
#######################################
# Body section: intro (What/Why/Tracking/Hypothesis intro).
# Args: $1=issue, $2=slug, $3=breaker_label, $4=trip_marker,
#        $5=failure_count, $6=safe_reason, $7=cost_block
#######################################
_cb_meta_body_intro() {
	local issue_number="$1" repo_slug="$2" breaker_label="$3"
	local trip_marker="$4" failure_count="$5" safe_reason="$6"
	local cost_block="$7"

	cat <<EOF
<!-- aidevops:generator=circuit-breaker-meta-filer -->

## What

Diagnose why the **${breaker_label}** circuit breaker fired on ${repo_slug}#${issue_number} after ${failure_count} consecutive worker failure(s), and ship the systemic fix that prevents the same class of failure on subsequent issues.

The breaker tripping is the SYMPTOM. This issue is for finding and fixing the ROOT CAUSE — typically a dispatch path bug, a worker setup race, an exit-classifier defect, or a brief-quality gap that caused workers to crash before reading the brief.

## Why

The existing breaker (\`${breaker_label}\`) halts dispatch with \`status:blocked\` on the original. Filing this meta-issue converts the trip into a self-healing cycle: forensics → hypothesis → fix → original unblocks automatically.

The original (#${issue_number}) gets a \`blocked-by\` label pointing at this meta-issue and clears automatically when this meta-issue's PR merges (handled by \`pulse-merge.sh::_unblock_circuit_breaker_meta_original\`).

## Tracking original issue

- Original: ${repo_slug}#${issue_number}
- Breaker: \`${breaker_label}\` (\`${trip_marker}\`)
- Failure count: ${failure_count}
- Last failure reason: ${safe_reason}${cost_block}

## Hypothesis (starting point — verify first)

The most common root causes for \`${breaker_label}\` trips are:

EOF
	return 0
}

#######################################
# Body section: hypothesis bullets specific to the breaker class.
# Args: $1=breaker_type
#######################################
_cb_meta_body_hypothesis() {
	local breaker_type="$1"

	if [[ "$breaker_type" == "$_CB_BREAKER_NO_WORK" ]]; then
		cat <<'EOF'
- **Worker exit classifier defect** — workers killed by SIGTERM/SIGKILL before producing a session may be misclassified as `reason=clean` (see #21818 / #21754). Check `headless-runtime-failure.sh::classify_worker_exit` and the wait_status sentinel propagation.
- **Stale-recovery false positive** — assignment recovery may mark active work as stale and record `stale_timeout` / `no_work` fast-fails. Check `dispatch-dedup-stale.sh::_is_stale_assignment`, especially comment pagination/slurping and last-activity aggregation on long issue threads.
- **Plugin init crash** — opencode plugin (`opencode-aidevops`) failing during boot due to FD exhaustion, env pollution, or a stale cache. Check the worker's stderr in `~/.aidevops/logs/worker-*-stderr.log`.
- **Branch naming race** — worker tries to checkout a branch that another concurrent worker just consumed.
- **Auth refresh race** — `gh` token rotation interrupts the worker mid-setup.
- **Footprint overlap** — another open issue/PR touches the same files; `dispatch-dedup-helper.sh` defers and the worker exits clean (this is the normal/expected case for `no_work` and should not trip the breaker — investigate why it did).
EOF
	else
		cat <<'EOF'
- **Brief is unimplementable as written** — refine scope or split the task; flag for `needs-decomposition`.
- **Hidden blocker** — missing dependency, environment issue, design conflict that cumulative worker attempts could not resolve.
- **Worker stuck in a loop** — model can't decompose the task; consider tier escalation OR scope reduction.
- **Wrong tier assigned** — downgrade a `tier:thinking` task to `standard`, or vice versa.
- **Breaker firing too early** — calibration problem in `dispatch-cost-budgets.conf`; investigate whether the budget is reasonable for the tier.
EOF
	fi
	return 0
}

#######################################
# Body section: How / Forensics / Acceptance / Verification.
# Args: $1=issue, $2=slug, $3=max_lines, $4=log_slice, $5=stages_slice
#######################################
_cb_meta_body_guidance() {
	local issue_number="$1" repo_slug="$2" max_lines="$3"
	local log_slice="$4" stages_slice="$5"

	cat <<EOF

## How (mentor's guidance for the next worker)

Treat the original (#${issue_number}) as evidence, not as the work to do. The work is **here** — diagnose the systemic gap that lets workers fail in this pattern, ship the fix, and the original unblocks itself.

### Files to inspect first

- \`EDIT: .agents/scripts/dispatch-dedup-cost.sh\` — t2007 cost breaker definition and trip site.
- \`EDIT: .agents/scripts/worker-lifecycle-common.sh\` — t2769 no_work breaker definition and trip site (around the \`no_work_loop\` marker).
- \`EDIT: .agents/scripts/dispatch-dedup-stale.sh::_is_stale_assignment\` — stale assignment recovery path; for \`no_work\` trips, verify comment pagination/slurping and last-activity aggregation before changing exit classification.
- \`EDIT: .agents/scripts/headless-runtime-failure.sh\` — worker exit classifier (the prime suspect for misclassification).
- \`EDIT: .agents/scripts/circuit-breaker-meta-filer.sh\` — this filer; if it filed too eagerly, fix the trip-detection upstream rather than the filer.
- \`EDIT: .agents/scripts/pulse-merge.sh::_handle_post_merge_actions\` — meta-PR merge cleanup that unblocks the original.

### Reference pattern

- Existing structural breaker paths in \`worker-lifecycle-common.sh\` (no_work) and \`dispatch-dedup-cost.sh\` (cost) for the trip → \`status:blocked\` → comment flow that this filer hooks into.
- \`pulse-nmr-approval.sh::_nmr_application_is_circuit_breaker_trip\` only for backward-compatible recognition of pre-migration NMR episodes (this filer's marker \`${_CB_META_MARKER}\` is also recognised).

### Forensics: pulse log slice (last ${max_lines} lines mentioning the issue)

\`\`\`
${log_slice:-(no matching log lines)}
\`\`\`

### Forensics: dispatch stages (\`dispatch-stages.tsv\` slice)

\`\`\`
${stages_slice:-(no matching stage records)}
\`\`\`

### Acceptance

1. Root cause identified and named explicitly in the PR description (which file/function/race).
2. Fix lands as a normal PR with \`Resolves #<this>\` (NOT \`Resolves #${issue_number}\` — this meta-issue is the unit of work, the original is downstream).
3. PR merge automatically removes the meta blocker label that points from the original issue to this meta-issue via \`_unblock_circuit_breaker_meta_original\`.
4. If no other \`blocked-by:*\` labels remain on #${issue_number}, \`status:available\` is restored automatically.
5. A regression test exists for the specific failure mode identified (test in \`.agents/scripts/tests/\`).

### Verification

\`\`\`bash
# After the fix lands and #${issue_number} unblocks, dispatch should proceed normally:
gh issue view ${issue_number} --repo ${repo_slug} --json labels --jq '[.labels[].name]'
# Expect: status:available and no blocked-by label for the meta-issue

# Re-run the regression tests:
bash .agents/scripts/tests/test-circuit-breaker-meta-filer.sh
bash .agents/scripts/tests/test-dispatch-dedup-stale-pagination.sh
\`\`\`
EOF
	return 0
}

#######################################
# Body section: Files Scope / Tier Checklist / Auto-filed-by tail.
# Args: (none)
#######################################
_cb_meta_body_tail() {
	cat <<'EOF'

## Files Scope

- `.agents/scripts/dispatch-dedup-cost.sh`
- `.agents/scripts/dispatch-dedup-stale.sh`
- `.agents/scripts/worker-lifecycle-common.sh`
- `.agents/scripts/headless-runtime-failure.sh`
- `.agents/scripts/headless-runtime-helper.sh`
- `.agents/scripts/circuit-breaker-meta-filer.sh`
- `.agents/scripts/pulse-merge.sh`
- `.agents/scripts/pulse-merge-feedback.sh`
- `.agents/scripts/pulse-nmr-approval.sh`
- `.agents/scripts/tests/**`

## Tier Checklist

- [x] Architecture: cross-cutting between dispatch + lifecycle + merge paths.
- [x] LLM judgment needed for hypothesis selection and root-cause naming.
- [x] No verbatim oldString/newString possible — design + integration work.

## Auto-filed by

`circuit-breaker-meta-filer.sh` (t3076). To suppress: set `AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE=1` in the pulse environment.
EOF
	return 0
}

_cb_meta_body() {
	local issue_number="$1"
	local repo_slug="$2"
	local breaker_type="$3"
	local failure_count="$4"
	local reason="${5:-}"
	local tier="${6:-}"
	local spent="${7:-}"
	local budget="${8:-}"

	local max_lines="${AIDEVOPS_CIRCUIT_BREAKER_META_FORENSIC_LINES:-50}"

	local breaker_label="$_CB_LABEL_NO_WORK" trip_marker='cost-circuit-breaker:no_work_loop'
	if [[ "$breaker_type" == "$_CB_BREAKER_COST" ]]; then
		breaker_label="$_CB_LABEL_COST"
		trip_marker='cost-circuit-breaker:fired'
	fi

	local log_slice stages_slice
	log_slice=$(_cb_meta_log_slice "$issue_number" "$max_lines")
	stages_slice=$(_cb_meta_stages_slice "$issue_number")

	local cost_block=""
	if [[ "$breaker_type" == "$_CB_BREAKER_COST" && -n "$spent" && -n "$budget" ]]; then
		cost_block="
- **Tier**: \`tier:${tier:-standard}\`
- **Spent**: ${spent} tokens
- **Budget**: ${budget} tokens"
	fi

	local safe_reason
	safe_reason=$(_sanitize_markdown "${reason:-(not provided)}" 2>/dev/null || printf '%s' "${reason:-(not provided)}")

	_cb_meta_body_intro "$issue_number" "$repo_slug" "$breaker_label" \
		"$trip_marker" "$failure_count" "$safe_reason" "$cost_block"
	_cb_meta_body_hypothesis "$breaker_type"
	_cb_meta_body_guidance "$issue_number" "$repo_slug" "$max_lines" \
		"$log_slice" "$stages_slice"
	_cb_meta_body_tail
	return 0
}

#######################################
# Apply blocked-by:<meta-ref> label to the original issue and post the
# marker comment that records the meta-issue number for idempotency.
#
# Args: $1=original_issue, $2=original_repo, $3=meta_repo,
#       $4=meta_issue_number, $5=breaker_type, $6=failure_count
#######################################
_cb_meta_link_original() {
	local original_issue="$1"
	local repo_slug="$2"
	local meta_repo="$3"
	local meta_number="$4"
	local breaker_type="$5"
	local failure_count="$6"

	local breaker_label="$_CB_LABEL_NO_WORK"
	[[ "$breaker_type" == "$_CB_BREAKER_COST" ]] && breaker_label="$_CB_LABEL_COST"

	# Best-effort: ensure the blocked-by label exists, then apply it.
	# We use a per-meta label so multiple concurrent breakers can each
	# unblock independently (matches t2442 parent-task linkage style).
	local blocked_label
	blocked_label=$(_cb_meta_blocked_label "$repo_slug" "$meta_repo" "$meta_number")
	if ! set_issue_status "$original_issue" "$repo_slug" "blocked" \
		--add-label "$blocked_label" >/dev/null 2>&1; then
		gh issue edit "$original_issue" --repo "$repo_slug" \
			--remove-label "status:available" \
			--remove-label "status:queued" \
			--remove-label "status:claimed" \
			--remove-label "status:in-progress" \
			--remove-label "status:in-review" \
			--add-label "status:blocked" \
			--add-label "$blocked_label" >/dev/null 2>&1 || true
	fi

	local tracking_ref="#${meta_number}"
	if [[ "$repo_slug" != "$meta_repo" ]]; then
		tracking_ref="${meta_repo}#${meta_number}"
	fi

	# Marker comment for idempotency. The HTML marker line is the canonical
	# idempotency signal; the human-readable text is for maintainers.
	local body
	body="<!-- ${_CB_META_MARKER}:${tracking_ref} -->
## Circuit Breaker Meta-Issue Filed (t3076)

The **${breaker_label}** breaker tripped after ${failure_count} consecutive failure(s) on this issue. A root-cause meta-issue has been filed:

→ Tracking: ${tracking_ref}

This issue is now \`status:blocked\` by \`${blocked_label}\` and will unblock automatically when the meta-issue's PR merges.

_Auto-filed by \`circuit-breaker-meta-filer.sh\` (t3076). Set \`AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE=1\` to suppress._"

	gh_issue_comment "$original_issue" --repo "$repo_slug" \
		--body "$body" 2>/dev/null || true

	return 0
}

#######################################
# CLI: file a meta-issue for a tripped circuit breaker.
#
# Required:
#   --issue NNN
#   --repo SLUG
#   --breaker {cost|no_work}
#   --failure-count N
#
# Optional:
#   --reason TEXT       last failure reason (free-text)
#   --tier T            tier label (cost breaker only)
#   --spent N           token spend (cost breaker only)
#   --budget N          token budget (cost breaker only)
#
# Stdout: meta-issue URL on success
# Returns: 0=success or idempotent skip, 1=arg error, 2=gh failure
#######################################
#######################################
# Parse `cmd_file` long-options into globals consumed by cmd_file.
# Sets: _CB_ARG_ISSUE, _CB_ARG_REPO, _CB_ARG_BREAKER, _CB_ARG_FAILURE_COUNT,
#       _CB_ARG_REASON, _CB_ARG_TIER, _CB_ARG_SPENT, _CB_ARG_BUDGET.
# Args: $@=cmd_file argv
# Returns: 0 on success, 1 on unknown flag.
#######################################
_cb_meta_parse_file_args() {
	_CB_ARG_ISSUE="" _CB_ARG_REPO="" _CB_ARG_BREAKER="" _CB_ARG_FAILURE_COUNT=""
	_CB_ARG_REASON="" _CB_ARG_TIER="" _CB_ARG_SPENT="" _CB_ARG_BUDGET=""

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--issue) _CB_ARG_ISSUE="${2:-}"; shift 2 ;;
		--repo) _CB_ARG_REPO="${2:-}"; shift 2 ;;
		--breaker) _CB_ARG_BREAKER="${2:-}"; shift 2 ;;
		--failure-count) _CB_ARG_FAILURE_COUNT="${2:-}"; shift 2 ;;
		--reason) _CB_ARG_REASON="${2:-}"; shift 2 ;;
		--tier) _CB_ARG_TIER="${2:-}"; shift 2 ;;
		--spent) _CB_ARG_SPENT="${2:-}"; shift 2 ;;
		--budget) _CB_ARG_BUDGET="${2:-}"; shift 2 ;;
		*)
			log_error "[circuit-breaker-meta-filer] unknown arg: $arg" >&2
			return 1
			;;
		esac
	done
	return 0
}

cmd_file() {
	_cb_meta_parse_file_args "$@" || return 1

	local issue_number="$_CB_ARG_ISSUE"
	local repo_slug="$_CB_ARG_REPO"
	local breaker_type="$_CB_ARG_BREAKER"
	local failure_count="$_CB_ARG_FAILURE_COUNT"
	local reason="$_CB_ARG_REASON"
	local tier="$_CB_ARG_TIER"
	local spent="$_CB_ARG_SPENT"
	local budget="$_CB_ARG_BUDGET"
	local meta_repo=""

	if [[ "${AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE:-0}" == "1" ]]; then
		log_info "[circuit-breaker-meta-filer] disabled via AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE — skip" >&2
		return 0
	fi

	if [[ -z "$issue_number" || -z "$repo_slug" || -z "$breaker_type" || -z "$failure_count" ]]; then
		log_error "[circuit-breaker-meta-filer] required: --issue --repo --breaker --failure-count" >&2
		return 1
	fi

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ ! "$failure_count" =~ ^[0-9]+$ ]]; then
		log_error "[circuit-breaker-meta-filer] --issue and --failure-count must be integers" >&2
		return 1
	fi

	if [[ "$breaker_type" != "$_CB_BREAKER_COST" && "$breaker_type" != "$_CB_BREAKER_NO_WORK" ]]; then
		log_error "[circuit-breaker-meta-filer] --breaker must be '${_CB_BREAKER_COST}' or '${_CB_BREAKER_NO_WORK}'" >&2
		return 1
	fi

	meta_repo=$(_cb_meta_target_repo "$repo_slug")
	[[ -n "$meta_repo" ]] || meta_repo="$repo_slug"

	# Idempotency: bail out if a meta-issue already exists for this original.
	local existing_meta
	existing_meta=$(_cb_meta_existing "$issue_number" "$repo_slug")
	if [[ -n "$existing_meta" ]]; then
		local existing_repo="${existing_meta%#*}"
		local existing_number="${existing_meta##*#}"
		log_info "[circuit-breaker-meta-filer] idempotent: meta-issue ${existing_meta} already filed for ${repo_slug}#${issue_number}" >&2
		printf 'https://github.com/%s/issues/%s\n' "$existing_repo" "$existing_number"
		return 0
	fi

	local body title
	body=$(_cb_meta_body "$issue_number" "$repo_slug" "$breaker_type" \
		"$failure_count" "$reason" "$tier" "$spent" "$budget")

	local breaker_label="$_CB_LABEL_NO_WORK"
	[[ "$breaker_type" == "$_CB_BREAKER_COST" ]] && breaker_label="$_CB_LABEL_COST"
	title="Circuit-breaker meta: diagnose ${breaker_label} trip on ${repo_slug}#${issue_number}"

	local labels="${AIDEVOPS_CIRCUIT_BREAKER_META_LABELS:-${_CB_META_DEFAULT_LABELS}}"

	local meta_url
	if ! meta_url=$(gh_create_issue --repo "$meta_repo" \
		--title "$title" \
		--body "$body" \
		--label "$labels" 2>&1); then
		log_error "[circuit-breaker-meta-filer] gh_create_issue failed: ${meta_url}" >&2
		return 2
	fi

	# Extract issue number from URL
	local meta_number
	meta_number=$(printf '%s' "$meta_url" |
		grep -oE 'github\.com/[^[:space:]]+/[^[:space:]]+/issues/[0-9]+' |
		head -1 |
		grep -oE '[0-9]+$' || true)
	if [[ -z "$meta_number" ]]; then
		log_error "[circuit-breaker-meta-filer] could not parse meta-issue number from URL: ${meta_url}" >&2
		return 2
	fi

	_cb_meta_link_original "$issue_number" "$repo_slug" "$meta_repo" \
		"$meta_number" "$breaker_type" "$failure_count"

	log_success "[circuit-breaker-meta-filer] filed meta-issue ${meta_url} in ${meta_repo} for ${repo_slug}#${issue_number} (${breaker_label}, count=${failure_count})" >&2
	printf '%s\n' "$meta_url"
	return 0
}

#######################################
# Extract the original issue ref from a meta-issue's body.
# The meta-issue body contains a "## Tracking original issue" section
# with a line "- Original: <slug>#<NNN>". This function returns that
# full ref for the given meta-issue number.
#
# Args: $1=meta_issue_number, $2=repo_slug
# Stdout: original issue ref (owner/repo#number), or empty
# Returns: 0 always (best-effort)
#######################################
_cb_meta_extract_original() {
	local meta_number="$1"
	local repo_slug="$2"

	local body
	body=$(gh api "repos/${repo_slug}/issues/${meta_number}" \
		--jq '.body // ""' 2>/dev/null) || body=""
	[[ -z "$body" || "$body" == "null" ]] && return 0

	# Match "- Original: owner/repo#NNN" — slug-aware so cross-repo metas
	# resolve the repo to unblock, not just the issue number.
	printf '%s' "$body" |
		grep -E '^- Original: ' |
		head -1 |
		grep -oE '[^[:space:]#]+/[^[:space:]#]+#[0-9]+' |
		head -1 || true
	return 0
}

#######################################
# Check whether any current blocked-by label remains after one meta fix merges.
# Immutable historical comments cannot represent current blocker state.
# Args: $1=original_issue, $2=repo_slug
# Returns: 0 if another blocker remains, 1 if dispatch may be restored
#######################################
_cb_meta_other_blockers_remain() {
	local original_issue="$1"
	local repo_slug="$2"
	local blocked_count=""
	blocked_count=$(gh issue view "$original_issue" --repo "$repo_slug" \
		--json labels --jq '[.labels[]?.name | select(startswith("blocked-by:"))] | length' \
		2>/dev/null) || return 0
	[[ "$blocked_count" =~ ^[0-9]+$ ]] || return 0
	[[ "$blocked_count" -gt 0 ]] && return 0
	return 1
}

#######################################
# Unblock an original issue when its meta-issue's PR has merged.
# Removes the blocked-by label for the meta; if no other current blocker labels
# remain, restores status:available and posts an unblock comment.
# Idempotent — second call is a no-op.
#
# Args: $1=meta_issue_number, $2=repo_slug
# Returns: 0 on success / no-op, 2 on gh failure
#######################################
cmd_unblock_on_merge() {
	local meta_number=""
	local repo_slug=""

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--meta)
			meta_number="${2:-}"
			shift 2
			;;
		--repo)
			repo_slug="${2:-}"
			shift 2
			;;
		*)
			log_error "[circuit-breaker-meta-filer] unblock: unknown arg: $arg" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$meta_number" || -z "$repo_slug" ]]; then
		log_error "[circuit-breaker-meta-filer] unblock: required: --meta --repo" >&2
		return 1
	fi

	local original_ref
	original_ref=$(_cb_meta_extract_original "$meta_number" "$repo_slug")
	if [[ -z "$original_ref" ]]; then
		log_info "[circuit-breaker-meta-filer] unblock: no original-issue line in #${meta_number} body — not a meta-issue, skip" >&2
		return 0
	fi

	local original_repo="${original_ref%#*}"
	local original_issue="${original_ref##*#}"
	if [[ -z "$original_repo" || ! "$original_issue" =~ ^[0-9]+$ ]]; then
		log_info "[circuit-breaker-meta-filer] unblock: invalid original ref '${original_ref}' in #${meta_number} body — skip" >&2
		return 0
	fi

	local blocked_label
	blocked_label=$(_cb_meta_blocked_label "$original_repo" "$repo_slug" "$meta_number")
	gh issue edit "$original_issue" --repo "$original_repo" \
		--remove-label "$blocked_label" 2>/dev/null || true
	if [[ "$blocked_label" != "blocked-by:#${meta_number}" ]]; then
		gh issue edit "$original_issue" --repo "$original_repo" \
			--remove-label "blocked-by:#${meta_number}" 2>/dev/null || true
	fi

	local dispatch_released="no"
	if ! _cb_meta_other_blockers_remain "$original_issue" "$original_repo"; then
		if set_issue_status "$original_issue" "$original_repo" "available" 2>/dev/null; then
			dispatch_released="yes"
		fi
	fi

	gh_issue_comment "$original_issue" --repo "$original_repo" \
		--body "<!-- circuit-breaker-meta-unblocked:#${meta_number} -->
## Circuit Breaker Meta-Issue Resolved (t3076)

The meta-issue ${repo_slug}#${meta_number} (which was diagnosing the breaker trip on this issue) has merged its fix. \`${blocked_label}\` has been removed.

Dispatch released: **${dispatch_released}** _(no other \`blocked-by:*\` labels remained)_.

If dispatch should now proceed, the next pulse cycle will pick this up.

_Auto-released by \`circuit-breaker-meta-filer.sh\` (t3076) via \`pulse-merge.sh::_handle_post_merge_actions\`._" 2>/dev/null || true

	log_success "[circuit-breaker-meta-filer] unblocked ${original_repo}#${original_issue} (meta=${repo_slug}#${meta_number}, dispatch_released=${dispatch_released})" >&2
	return 0
}

cmd_help() {
	cat <<'EOF'
circuit-breaker-meta-filer.sh — File root-cause meta-issues for tripped breakers (t3076)

USAGE:
  circuit-breaker-meta-filer.sh file --issue NNN --repo SLUG \
    --breaker {cost|no_work} --failure-count N \
    [--reason "text"] [--tier T] [--spent N] [--budget N]

  circuit-breaker-meta-filer.sh unblock-on-merge --meta NNN --repo SLUG

  circuit-breaker-meta-filer.sh help

ENVIRONMENT:
  AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE   set to 1 to disable
  AIDEVOPS_CIRCUIT_BREAKER_META_LABELS         override labels (CSV)
  AIDEVOPS_CIRCUIT_BREAKER_META_TARGET_REPO    force meta-issue target repo
  AIDEVOPS_CIRCUIT_BREAKER_META_FRAMEWORK_REPO framework source repo fallback
  AIDEVOPS_CIRCUIT_BREAKER_META_FORENSIC_LINES max log lines (default 50)

EXIT CODES:
  0 = filed (or idempotent skip / disabled)
  1 = invalid arguments
  2 = gh API failure

WIRED BY:
  worker-lifecycle-common.sh (t2769 no_work)
  dispatch-dedup-cost.sh     (t2007 cost)

CLEANUP:
  pulse-merge.sh::_unblock_circuit_breaker_meta_original removes
  the meta blocked-by label from the original when the meta-PR merges.
EOF
	return 0
}

# Allow sourcing without executing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	subcmd="${1:-help}"
	shift || true
	case "$subcmd" in
	file) cmd_file "$@" ;;
	unblock-on-merge) cmd_unblock_on_merge "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown subcommand: ${subcmd}" >&2
		cmd_help >&2
		exit 1
		;;
	esac
fi
