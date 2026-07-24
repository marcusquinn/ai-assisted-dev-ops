#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-worker-launch.sh — Worker launch helpers — assignment, log setup, tier/model resolution, worktree pre-creation, nohup launch, post-launch hooks, and thin orchestrator.
#
# Extracted from pulse-dispatch-core.sh (GH#18832) to bring that file
# below the 2000-line simplification gate.
#
# This module is sourced by pulse-dispatch-core.sh. Depends on
# shared-constants.sh and worker-lifecycle-common.sh being sourced first.
#
# Functions in this module (in source order):
#   - _dlw_assign_and_label
#   - _dlw_setup_worker_log
#   - _dlw_resolve_tier_and_model
#   - _dlw_precreate_worktree
#   - _dlw_renew_prelaunch_lease
#   - _dlw_prewarm_opencode_db
#   - _dlw_prepare_opencode_db
#   - _dlw_exec_detached
#   - _dlw_exec_systemd_user_service
#   - _dlw_spawn_early_exit_monitor
#   - _dlw_spawn_lifecycle_observer (t3055/GH#21870)
#   - _dlw_nohup_launch
#   - _dlw_post_launch_hooks
#   - _dlw_check_worker_branch_orphan_loop
#   - _dispatch_launch_worker

[[ -n "${_PULSE_DISPATCH_WORKER_LAUNCH_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_WORKER_LAUNCH_LOADED=1
readonly _DLW_STANDARD_TIER="standard"

_DLW_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
if [[ -r "${_DLW_SCRIPT_DIR}/lib/version.sh" ]]; then
	# shellcheck source=lib/version.sh
	source "${_DLW_SCRIPT_DIR}/lib/version.sh"
fi
if [[ -r "${_DLW_SCRIPT_DIR}/gh-signature-helper-detect.sh" ]]; then
	# shellcheck source=gh-signature-helper-detect.sh
	source "${_DLW_SCRIPT_DIR}/gh-signature-helper-detect.sh"
fi
unset _DLW_SCRIPT_DIR
: "${AIDEVOPS_UNKNOWN_VERSION:=unknown}"
if [[ -z "${_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN+x}" ]]; then
	# shellcheck disable=SC2016  # The backticks are literal review text matched in comments.
	_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN='CLAIM_RELEASED reason=worker_noop_zero_output|worker_noop_zero_output|zero[- ]output|classified as `no_work`'
fi

_dlw_display_version_or_unknown() {
	local raw_version="$1"
	if declare -F aidevops_display_version >/dev/null 2>&1; then
		aidevops_display_version "$raw_version"
	else
		if [[ -n "$raw_version" && "$raw_version" != "$AIDEVOPS_UNKNOWN_VERSION" ]]; then
			printf 'v%s' "$raw_version"
		else
			printf '%s' "$AIDEVOPS_UNKNOWN_VERSION"
		fi
	fi
	return 0
}

#######################################
# Post-clearance worker launch for dispatch_with_dedup.
# Extracted from dispatch_with_dedup (t1999, Phase 12) to reduce the
# parent function to a thin orchestrator.
#
# Executes all post-clearance steps after _dispatch_dedup_check_layers
# has confirmed the issue is safe to dispatch:
#   - Issue edit: replace assignees, add status:queued + origin:worker
#   - Worker log file setup (per-issue temp log, GH#14483)
#   - Model/tier resolution (round-robin, t1997)
#   - Issue + linked PR lock (t1894/t1934)
#   - Git pull to latest remote commit (GH#17584)
#   - Worktree pre-creation for the worker (5-8 tool call savings)
#   - Worker command construction + nohup launch (GH#17549)
#   - Stagger delay (SQLite contention, GH#17549)
#   - Dispatch ledger registration (tier telemetry)
#   - Deterministic dispatch comment (GH#15317)
#   - Claim comment audit trail retention (GH#17503)
#
# Arguments:
#    $1 - issue_number
#    $2 - repo_slug (owner/repo)
#    $3 - dispatch_title
#    $4 - issue_title
#    $5 - self_login (dispatching runner login)
#    $6 - repo_path (local path to the repo)
#    $7 - prompt (worker prompt string)
#    $8 - session_key
#    $9 - model_override (empty = auto-select via round-robin)
#   $10 - issue_meta_json (pre-fetched JSON: number,title,state,labels,assignees)
#
# Dynamic scoping: reads/writes _claim_comment_id from the calling
# dispatch_with_dedup frame (set by check_dispatch_dedup, GH#15317).
# Do NOT declare local _claim_comment_id here — it must remain in the
# caller's scope so the value survives the function return.
#
# Exit codes:
#   0 - worker launched successfully
#   non-zero - launch failed (logged to LOGFILE)
#######################################
#######################################
# Atomically swap issue assignment to the dispatching runner and apply
# status labels for a queued worker (GH#17777, t2033).
#
# Previous behavior only added self (--add-assignee), leaving the original
# assignee (typically the issue creator) co-assigned. This created ambiguity
# about ownership and confused dedup layer 6 (is_assigned) when status:queued
# made passive owner assignments appear active.
#
# t2033: use set_issue_status to atomically clear sibling status:* labels.
# Before t2033, this call site added status:queued without removing
# status:available — #18444/#18454/#18455 accumulated both labels and
# broke t2008 stale-recovery tick counting.
#
# Arguments: issue_number, repo_slug, self_login, issue_meta_json
#######################################
_dlw_assign_and_label() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local issue_meta_json="$4"

	# Preserve origin:* labels as immutable creation provenance. Worker claim is
	# represented by status:queued + assignee; origin:worker is only for issues
	# created by workers, not issues currently being handled by workers.
	local -a _extra_flags=(--add-assignee "$self_login"
	)
	local _prev_login
	while IFS= read -r _prev_login; do
		[[ -n "$_prev_login" && "$_prev_login" != "$self_login" ]] && _extra_flags+=(--remove-assignee "$_prev_login")
	done < <(printf '%s' "$issue_meta_json" | jq -r '.assignees[].login' 2>/dev/null)

	if ! set_issue_status "$issue_number" "$repo_slug" "queued" "${_extra_flags[@]}"; then
		echo "[dispatch_with_dedup] Failed to assign queued ownership for #${issue_number} in ${repo_slug}; aborting before lock/worktree/spawn" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Create per-issue worker log files with a shared fallback symlink (GH#14483).
# The primary log is namespaced by repo_slug + issue_number; the fallback is
# a plain `pulse-{issue}.log` symlink in the same per-user pulse temp dir.
#
# Arguments: repo_slug, issue_number
# Stdout: absolute path to the primary worker log
#######################################
_dlw_setup_worker_log() {
	local repo_slug="$1"
	local issue_number="$2"
	local worker_log="" worker_log_fallback=""
	aidevops_pulse_tmp_cleanup "${AIDEVOPS_PULSE_TMP_MAX_AGE_MINUTES:-2880}" || true
	worker_log=$(aidevops_pulse_worker_log_path "$repo_slug" "$issue_number") || return 1
	worker_log_fallback=$(aidevops_pulse_worker_log_fallback_path "$issue_number") || return 1
	rm -f "$worker_log" "$worker_log_fallback"
	: >"$worker_log"
	ln -s "$worker_log" "$worker_log_fallback" 2>/dev/null || true
	printf '%s\n' "$worker_log"
	return 0
}

#######################################
# Resolve the dispatch tier from labels and select a worker model.
# Populates three module-level globals so the orchestrator can read them
# without the complexity of multi-value stdout parsing (bash 3.2 has no
# namerefs — pattern from GH#18705 decomposition memory lesson):
#   _DLW_DISPATCH_TIER        — cascade tier name: simple|standard|thinking
#   _DLW_DISPATCH_MODEL_TIER  — runtime tier: simple|standard|thinking|bundle tier
#   _DLW_SELECTED_MODEL       — concrete model name, or empty for auto-select
#
# ROUND-ROBIN MODEL SELECTION (owned by this helper, NOT the caller).
# When model_override is EMPTY, calls headless-runtime-helper.sh select
# --role worker, which resolves the worker model from the routing table /
# local override (respecting backoff DB, auth availability, provider
# allowlists, and rotation). The resolved model name is shown in the
# dispatch comment so the audit trail records exactly which provider/model
# the worker used.
#
# IMPORTANT: Callers MUST NOT pass a model override for default dispatches.
# Only pass model_override when a specific tier is required. Passing an
# arbitrary model here bypasses the round-robin and causes provider
# imbalance. History: GH#17503 moved model resolution here from the worker.
#
# Arguments: issue_meta_json, model_override, repo_path
#######################################
_dlw_resolve_tier_and_model() {
	local issue_meta_json="$1"
	local model_override="$2"
	local repo_path="${3:-}"

	_DLW_DISPATCH_TIER="$_DLW_STANDARD_TIER"
	_DLW_DISPATCH_MODEL_TIER="$_DLW_STANDARD_TIER"
	local issue_labels_csv
	issue_labels_csv=$(printf '%s' "$issue_meta_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels_csv=""
	_DLW_TRUSTED_ISSUE_PRIORITY=$(printf '%s' "$issue_meta_json" | jq -r '[.labels[]?.name | select(startswith("priority:"))][0] // "" | sub("^priority:"; "")' 2>/dev/null || true)
	# shellcheck disable=SC2016 # Backticks are literal optional Markdown delimiters.
	_DLW_TRUSTED_RELEASE_TYPE=$(printf '%s' "$issue_meta_json" | jq -r '.body // ""' 2>/dev/null | sed -nE 's/^\*\*Release scope:\*\*[[:space:]]*`?(patch|minor|major)`?[[:space:]]*$/\1/ip' | head -1)
	# shellcheck disable=SC2016 # Backticks are literal optional Markdown delimiters.
	_DLW_TRUSTED_DEPLOY_SCOPE=$(printf '%s' "$issue_meta_json" | jq -r '.body // ""' 2>/dev/null | sed -nE 's/^\*\*Deployment scope:\*\*[[:space:]]*`?(incremental|full)`?[[:space:]]*$/\1/ip' | head -1)
	local explicit_tier_label=0
	if _dlw_has_explicit_tier_label "$issue_labels_csv"; then
		explicit_tier_label=1
	fi

	# Resolve tier from labels, preferring highest rank when multiple present (t1997)
	local resolved_tier
	resolved_tier=$(_resolve_worker_tier "$issue_labels_csv")
	case "$resolved_tier" in
	tier:thinking)
		_DLW_DISPATCH_TIER="thinking"
		_DLW_DISPATCH_MODEL_TIER="thinking"
		;;
	tier:standard)
		_DLW_DISPATCH_TIER="$_DLW_STANDARD_TIER"
		_DLW_DISPATCH_MODEL_TIER="$_DLW_STANDARD_TIER"
		;;
	tier:simple)
		_DLW_DISPATCH_TIER="simple"
		_DLW_DISPATCH_MODEL_TIER="simple"
		;;
	esac

	# t1364.6: when issue labels do not force a tier, let project bundles
	# right-size worker model selection for implementation work. Explicit model
	# overrides and tier:* labels still win.
	if [[ -z "$model_override" && "$explicit_tier_label" -eq 0 && -n "$repo_path" ]]; then
		local bundle_tier
		bundle_tier=$(_dlw_bundle_model_tier "$repo_path") || bundle_tier=""
		if [[ -n "$bundle_tier" ]]; then
			_DLW_DISPATCH_TIER="bundle"
			_DLW_DISPATCH_MODEL_TIER="$bundle_tier"
		fi
	fi

	_DLW_SELECTED_MODEL=""
	if [[ -n "$model_override" ]]; then
		_DLW_SELECTED_MODEL="$model_override"
	else
		_DLW_SELECTED_MODEL=$("$HEADLESS_RUNTIME_HELPER" select --role worker --tier "$_DLW_DISPATCH_MODEL_TIER" 2>/dev/null) || _DLW_SELECTED_MODEL=""
	fi
	return 0
}

#######################################
# Check whether labels include an explicit worker tier.
# _resolve_worker_tier defaults unlabeled issues to tier:standard, so callers
# need this helper to distinguish an authored tier label from the fallback.
# Arguments:
#   $1 - comma-separated label list
# Returns: 0 when a tier:* label is present, 1 otherwise
#######################################
_dlw_has_explicit_tier_label() {
	local labels_csv="$1"
	local labels_lower
	labels_lower=$(printf '%s' "$labels_csv" | tr '[:upper:]' '[:lower:]')
	local labels_with_commas=",${labels_lower},"

	case "$labels_with_commas" in
	*,tier:thinking,* | *,tier:standard,* | *,tier:simple,*) return 0 ;;
	*) return 1 ;;
	esac
}

#######################################
# Resolve implementation model tier from the project bundle, if configured.
# Arguments:
#   $1 - repo_path
# Stdout: tier name (empty if unavailable)
#######################################
_dlw_bundle_model_tier() {
	local repo_path="$1"
	local bundle_helper="${_DLW_SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/bundle-helper.sh"

	if [[ -z "$repo_path" || ! -x "$bundle_helper" ]]; then
		return 0
	fi

	"$bundle_helper" get model_defaults.implementation "$repo_path" 2>/dev/null || true
	return 0
}

#######################################
# Classify a task into a coarse bundle agent_routing domain.
# Arguments:
#   $1 - issue_title
#   $2 - prompt
# Stdout: routing domain key
#######################################
_dlw_bundle_routing_domain() {
	local issue_title="$1"
	local prompt="$2"
	local text
	text=$(printf '%s %s' "$issue_title" "$prompt" | tr '[:upper:]' '[:lower:]')

	case "$text" in
	*seo* | *sitemap* | *schema* | *ranking* | *metadata* | *meta\ tag*)
		printf 'seo\n'
		return 0
		;;
	*content* | *blog* | *newsletter* | *social* | *video* | *copywriting*)
		printf 'content\n'
		return 0
		;;
	*accessibility* | *a11y* | *wcag*)
		printf 'accessibility\n'
		return 0
		;;
	*deploy* | *docker* | *terraform* | *infrastructure* | *cloudflare*)
		printf 'infrastructure\n'
		return 0
		;;
	*document* | *readme* | *docs*)
		printf 'documentation\n'
		return 0
		;;
	*)
		printf 'code\n'
		return 0
		;;
	esac
}

#######################################
# Resolve preferred worker agent from bundle agent_routing.
# Arguments:
#   $1 - repo_path
#   $2 - issue_title
#   $3 - prompt
# Stdout: agent name (empty if unavailable)
#######################################
_dlw_bundle_agent_name() {
	local repo_path="$1"
	local issue_title="$2"
	local prompt="$3"
	local bundle_helper="${_DLW_SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/bundle-helper.sh"

	if [[ -z "$repo_path" || ! -x "$bundle_helper" ]]; then
		return 0
	fi

	local domain
	domain=$(_dlw_bundle_routing_domain "$issue_title" "$prompt")
	"$bundle_helper" resolve "$repo_path" 2>/dev/null | jq -r --arg domain "$domain" \
		'.agent_routing[$domain] // .agent_routing.code // empty' 2>/dev/null || true
	return 0
}

_dlw_zero_output_failure_count() {
	local issue_number="$1"
	local repo_slug="$2"
	local precomputed_comment_count="${3:-}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
	[[ -n "$repo_slug" ]] || { printf '0'; return 0; }
	local state_count=0 comment_count=0
	if [[ "$precomputed_comment_count" =~ ^[0-9]+$ ]]; then
		comment_count="$precomputed_comment_count"
	else
		comment_count=$(_dlw_zero_output_comment_count "$issue_number" "$repo_slug")
		[[ "$comment_count" =~ ^[0-9]+$ ]] || comment_count=0
	fi
	[[ -n "${FAST_FAIL_STATE_FILE:-}" && -f "$FAST_FAIL_STATE_FILE" ]] || {
		printf '%s' "$comment_count"
		return 0
	}

	local key="${repo_slug}/${issue_number}"
	local result=""
	result=$(jq -r --arg k "$key" 'def s: . // ""; .[$k] | if . then [(.count // 0 | tostring), (.reason | s), (.crash_type | s)] | @tsv else empty end' "$FAST_FAIL_STATE_FILE") || result=""
	if [[ -z "$result" ]]; then
		printf '%s' "$comment_count"
		return 0
	fi

	local reason="" crash_type="" count=""
	IFS=$'\t' read -r count reason crash_type <<<"$result"
	[[ "$count" =~ ^[0-9]+$ ]] || count=0

	case "${reason}:${crash_type}" in
	worker_noop_zero_output:* | *:no_work | no_work:*) state_count="$count" ;;
	*) state_count=0 ;;
	esac
	if [[ "$comment_count" -gt "$state_count" ]]; then
		printf '%s' "$comment_count"
	else
		printf '%s' "$state_count"
	fi
	return 0
}

_dlw_zero_output_comment_count() {
	local issue_number="$1"
	local repo_slug="$2"
	local zero_output_pattern="${_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN}"

	[[ "${ZERO_OUTPUT_COMMENT_EVIDENCE_ENABLED:-1}" == "1" ]] || { printf '0'; return 0; }
	[[ "$issue_number" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
	[[ -n "$repo_slug" ]] || { printf '0'; return 0; }

	local count=""
	# shellcheck disable=SC2016  # jq program is intentionally single-quoted.
	count=$(gh api --paginate "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" \
		--jq '[.[] | select((.body // "") | test("'"${zero_output_pattern}"'"; "i"))] | length' 2>/dev/null | \
		awk '{ if ($1 ~ /^[0-9]+$/) { total += $1 } } END { printf "%d", total + 0 }') || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%s' "$count"
	return 0
}

_dlw_comment_bloat_metrics() {
	local issue_number="$1"
	local repo_slug="$2"
	local zero_output_pattern="${_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN}"

	[[ "${CLEAN_ROOM_COMMENT_EVIDENCE_ENABLED:-1}" == "1" ]] || { printf '0\t0\t0\t0'; return 0; }
	[[ "$issue_number" =~ ^[0-9]+$ ]] || { printf '0\t0\t0\t0'; return 0; }
	[[ -n "$repo_slug" ]] || { printf '0\t0\t0\t0'; return 0; }

	local metrics=""
	# shellcheck disable=SC2016  # jq program is intentionally single-quoted.
	metrics=$(gh api --paginate "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" \
		--jq '[.[] | {body: (.body // "")}] | {comments: length, ops: ([.[] | select(.body | test("ops:start|DISPATCH_CLAIM|CLAIM_RELEASED|dispatch-cooldown|Worker Watchdog Kill"; "i"))] | length), zero: ([.[] | select(.body | test("'"${zero_output_pattern}"'"; "i"))] | length), chars: ([.[].body | length] | add // 0)} | [.comments, .ops, .zero, .chars] | @tsv' \
		2>/dev/null | awk -F '\t' '{c+=$1; o+=$2; z+=$3; ch+=$4} END {printf "%d\t%d\t%d\t%d", c+0, o+0, z+0, ch+0}') || metrics="0	0	0	0"
	[[ -n "$metrics" ]] || metrics=$'0\t0\t0\t0'
	printf '%s' "$metrics"
	return 0
}

_dlw_comment_bloat_requires_clean_room() {
	local issue_number="$1"
	local repo_slug="$2"
	local precomputed_metrics="${3:-}"

	local comments=""
	local ops=""
	local zero=""
	local chars=""
	if [[ -z "$precomputed_metrics" ]]; then
		precomputed_metrics=$(_dlw_comment_bloat_metrics "$issue_number" "$repo_slug")
	fi
	IFS=$'\t' read -r comments ops zero chars \
		<<<"$precomputed_metrics"
	[[ "$comments" =~ ^[0-9]+$ ]] || comments=0
	[[ "$ops" =~ ^[0-9]+$ ]] || ops=0
	[[ "$zero" =~ ^[0-9]+$ ]] || zero=0
	[[ "$chars" =~ ^[0-9]+$ ]] || chars=0

	local comment_threshold="${CLEAN_ROOM_COMMENT_THRESHOLD:-100}"
	local ops_threshold="${CLEAN_ROOM_OPS_COMMENT_THRESHOLD:-50}"
	local zero_threshold="${CLEAN_ROOM_ZERO_OUTPUT_COMMENT_THRESHOLD:-10}"
	local chars_threshold="${CLEAN_ROOM_COMMENT_CHARS_THRESHOLD:-50000}"
	[[ "$comment_threshold" =~ ^[0-9]+$ ]] || comment_threshold=100
	[[ "$ops_threshold" =~ ^[0-9]+$ ]] || ops_threshold=50
	[[ "$zero_threshold" =~ ^[0-9]+$ ]] || zero_threshold=10
	[[ "$chars_threshold" =~ ^[0-9]+$ ]] || chars_threshold=50000

	if [[ "$comments" -ge "$comment_threshold" || "$ops" -ge "$ops_threshold" || "$zero" -ge "$zero_threshold" || "$chars" -ge "$chars_threshold" ]]; then
		echo "[dispatch_with_dedup] #${issue_number} in ${repo_slug}: clean-room brief mode for comment-bloated issue comments=${comments} ops=${ops} zero=${zero} chars=${chars}" >>"$LOGFILE"
		return 0
	fi
	return 1
}

_dlw_fetch_issue_body_for_clean_room() {
	local issue_number="$1"
	local repo_slug="$2"
	local snapshot_helper="${ISSUE_BODY_SNAPSHOT_HELPER:-${BASH_SOURCE[0]%/*}/issue-body-snapshot-helper.sh}"
	local issue_json=""

	[[ -x "$snapshot_helper" ]] || return 1
	issue_json=$("$snapshot_helper" fetch "$repo_slug" "$issue_number") || return 1
	jq -rj '.body' <<<"$issue_json"
	return $?
}

_dlw_clean_room_prompt() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"
	local issue_body="$4"

	cat <<EOF
You are assigned to work on issue #${issue_number} in ${repo_slug}.

This issue has a large audit/comment trail that is not implementation context. Use clean-room brief mode:

1. Do not read issue comments or timeline unless explicitly required by a maintainer.
2. Treat only the issue body below as the worker brief.
3. Ignore ops/provenance/audit comments, dispatch claims, release comments, watchdog comments, and cooldown comments.
4. Before editing, summarize the actionable task, files, and verification from the body below.
5. If the body is still not worker-ready, create a concise replacement child issue or add a maintainer-review comment instead of speculating.

Issue title: ${issue_title:-Issue #${issue_number}}

Clean issue body:

${issue_body:-No issue body was available. Read only the issue body with: gh issue view ${issue_number} --repo ${repo_slug} --json body --jq '.body'}
EOF
	return 0
}

_dlw_zero_output_evidence_count() {
	local issue_number="$1"
	local repo_slug="$2"
	local precomputed_comment_count="${3:-}"
	local precomputed_evidence_count="${4:-}"

	if [[ "$precomputed_evidence_count" =~ ^[0-9]+$ ]]; then
		printf '%s' "$precomputed_evidence_count"
		return 0
	fi

	local state_count="" comment_count=""
	if [[ "$precomputed_comment_count" =~ ^[0-9]+$ ]]; then
		comment_count="$precomputed_comment_count"
	else
		comment_count=$(_dlw_zero_output_comment_count "$issue_number" "$repo_slug")
	fi
	state_count=$(_dlw_zero_output_failure_count "$issue_number" "$repo_slug" "$comment_count")
	[[ "$state_count" =~ ^[0-9]+$ ]] || state_count=0
	[[ "$comment_count" =~ ^[0-9]+$ ]] || comment_count=0
	if [[ "$comment_count" -gt "$state_count" ]]; then
		printf '%s' "$comment_count"
	else
		printf '%s' "$state_count"
	fi
	return 0
}

_dlw_zero_output_fallback_prompt() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"
	local snapshot_ready="${4:-0}"
	local snapshot_instruction=""

	if [[ "$snapshot_ready" == "1" ]]; then
		snapshot_instruction="2. If that live read is unavailable, read the bounded validated snapshot with: ~/.aidevops/agents/scripts/issue-body-snapshot-helper.sh fetch ${repo_slug} ${issue_number}"
	else
		snapshot_instruction="2. No validated snapshot was captured. If the live read fails, stop and report that implementation is not authorized without trusted issue context."
	fi

	cat <<EOF
You are assigned to work on issue #${issue_number} in ${repo_slug}.

Previous dispatch attempts for this issue launched a worker but produced zero session output. Do not rely on embedded issue content from the dispatcher.

First actions:
1. Read the issue directly with: gh issue view ${issue_number} --repo ${repo_slug}
${snapshot_instruction}
3. Ignore ops/provenance/audit comments as implementation context.
4. Summarize the actionable task, files, and verification before editing.
5. If the issue brief is malformed, too broad, or not worker-ready, rewrite the brief or split it into smaller worker-ready issues instead of attempting a speculative implementation.

Issue title: ${issue_title:-Issue #${issue_number}}
EOF
	return 0
}

_dlw_first_pass_completion_contract() {
	cat <<'EOF'

First-pass completion contract:
1. Before editing, verify the issue is still open and not already satisfied by the default branch, an open/closed PR, or a pushed issue branch. Reuse salvageable commits instead of restarting.
2. Treat prior structured CI/review feedback in the issue body as cumulative evidence. Address every terminal failing check, including advisory checks, not only the first required failure.
3. Validate the stated target files and verification commands against the current dependency/runtime versions before implementation.
4. After the first coherent commit, push and create a draft PR early so progress is durable and visible to every runner. Continue implementation and local verification on that PR; do not hand off while it is draft or has unpushed changes. Once the completed exact head is pushed, the PR is non-draft, its merge summary exists, and one immediate remote check shows no terminal failure, attempt merge once. If only asynchronous CI, bot review, human approval, or native auto-merge remains, exit and hand off to pulse. Never poll those gates or bypass approval, review, CI, branch-protection, or security controls.
5. Do not post routine dispatch, stale, or progress comments. Prefer commits, the PR, check runs, and one final completion or blocker dossier.
EOF
	return 0
}

_dlw_validated_context_token() {
	local value="$1"
	if [[ "$value" =~ ^[A-Za-z0-9._:/-]{1,128}$ ]]; then
		printf '%s' "$value"
	else
		printf 'unknown'
	fi
	return 0
}

_dlw_prior_attempt_context() {
	local issue_number="$1"
	local repo_slug="$2"
	local helper="${OBJECTIVE_RECONCILIATION_HELPER:-${BASH_SOURCE[0]%/*}/objective-reconciliation-helper.sh}"
	local disposition=""
	local fields=""
	local empty_field="__AIDEVOPS_EMPTY_FIELD__"
	local source="" prior_attempt_id="" effective_outcome="" raw_result=""
	local status="" classification="" next_action=""
	local context=""
	local max_chars="${AIDEVOPS_RETRY_CONTEXT_MAX_CHARS:-1024}"

	[[ -x "$helper" ]] || return 0
	disposition=$("$helper" disposition --repo "$repo_slug" --issue "$issue_number" 2>/dev/null) || return 0
	fields=$(printf '%s' "$disposition" | jq -r --arg empty "$empty_field" \
		'[.source // "", .attempt_id // "", .effective_outcome // "", .raw_result // "", .status // "", .classification // "", .next_action // ""]
		| map(if . == "" then $empty else . end) | @tsv' 2>/dev/null) || return 0
	IFS=$'\t' read -r source prior_attempt_id effective_outcome raw_result status classification next_action <<<"$fields"
	[[ "$source" == "$empty_field" ]] && source=""
	[[ "$prior_attempt_id" == "$empty_field" ]] && prior_attempt_id=""
	[[ "$effective_outcome" == "$empty_field" ]] && effective_outcome=""
	[[ "$raw_result" == "$empty_field" ]] && raw_result=""
	[[ "$status" == "$empty_field" ]] && status=""
	[[ "$classification" == "$empty_field" ]] && classification=""
	[[ "$next_action" == "$empty_field" ]] && next_action=""
	case "$effective_outcome" in
	failed | deferred | escalated) ;;
	*) return 0 ;;
	esac
	source=$(_dlw_validated_context_token "$source")
	prior_attempt_id=$(_dlw_validated_context_token "$prior_attempt_id")
	effective_outcome=$(_dlw_validated_context_token "$effective_outcome")
	raw_result=$(_dlw_validated_context_token "$raw_result")
	status=$(_dlw_validated_context_token "$status")
	classification=$(_dlw_validated_context_token "$classification")
	next_action=$(_dlw_validated_context_token "$next_action")
	printf -v context '\nValidated prior-attempt state (machine-generated; prior model prose and issue comments are excluded):\n- source: %s\n- attempt_id: %s\n- effective_outcome: %s\n- raw_result: %s\n- status: %s\n- classification: %s\n- next_action: %s\nContinue from validated repository and PR state; do not repeat completed setup.' \
		"$source" "$prior_attempt_id" "$effective_outcome" "$raw_result" "$status" "$classification" "$next_action"
	[[ "$max_chars" =~ ^[0-9]+$ && "$max_chars" -ge 256 && "$max_chars" -le 4096 ]] || max_chars=1024
	if [[ "${#context}" -gt "$max_chars" ]]; then
		context="${context:0:max_chars}"
	fi
	printf '%s\n' "$context"
	return 0
}

_dlw_prepare_prompt_for_launch() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"
	local original_prompt="$4"
	local precomputed_comment_metrics="${5:-}"
	local comment_metrics=""
	local comments=""
	local ops=""
	local metrics_zero_count=""
	local chars=""
	local precomputed_zero_count=""
	local prior_attempt_context=""

	prior_attempt_context=$(_dlw_prior_attempt_context "$issue_number" "$repo_slug" || true)

	comment_metrics="$precomputed_comment_metrics"
	[[ -n "$comment_metrics" ]] || comment_metrics=$(_dlw_comment_bloat_metrics "$issue_number" "$repo_slug")
	IFS=$'\t' read -r comments ops metrics_zero_count chars <<<"$comment_metrics"
	if [[ "${CLEAN_ROOM_COMMENT_EVIDENCE_ENABLED:-1}" == "1" && "$metrics_zero_count" =~ ^[0-9]+$ ]]; then
		precomputed_zero_count="$metrics_zero_count"
	fi

	if _dlw_comment_bloat_requires_clean_room "$issue_number" "$repo_slug" "$comment_metrics"; then
		local issue_body=""
		if ! issue_body=$(_dlw_fetch_issue_body_for_clean_room "$issue_number" "$repo_slug"); then
			echo "[dispatch_with_dedup] #${issue_number} in ${repo_slug}: clean-room issue body unavailable; implementation is not authorized" >>"$LOGFILE"
			_dlw_clean_room_prompt "$issue_number" "$repo_slug" "$issue_title" "BLOCKER: The live issue body and its validated durable snapshot are unavailable. Do not implement from this prompt. Retry the live gh issue view command and report the snapshot validation error if it remains unavailable."
			return 0
		fi
		_dlw_clean_room_prompt "$issue_number" "$repo_slug" "$issue_title" "$issue_body"
		printf '%s' "$prior_attempt_context"
		_dlw_first_pass_completion_contract
		return 0
	fi

	local zero_count=""
	zero_count=$(_dlw_zero_output_evidence_count "$issue_number" "$repo_slug" "$precomputed_zero_count")
	[[ "$zero_count" =~ ^[0-9]+$ ]] || zero_count=0
	local fallback_threshold="${ZERO_OUTPUT_URL_FALLBACK_THRESHOLD:-2}"
	[[ "$fallback_threshold" =~ ^[0-9]+$ ]] || fallback_threshold=2

	if [[ "$zero_count" -ge "$fallback_threshold" ]]; then
		local snapshot_helper="${ISSUE_BODY_SNAPSHOT_HELPER:-${BASH_SOURCE[0]%/*}/issue-body-snapshot-helper.sh}"
		local snapshot_ready=0
		if [[ -x "$snapshot_helper" ]] && "$snapshot_helper" fetch "$repo_slug" "$issue_number" >/dev/null 2>&1; then
			snapshot_ready=1
		fi
		echo "[dispatch_with_dedup] #${issue_number} in ${repo_slug}: using URL-only bootstrap prompt after ${zero_count} zero-output launches" >>"$LOGFILE"
		_dlw_zero_output_fallback_prompt "$issue_number" "$repo_slug" "$issue_title" "$snapshot_ready"
		printf '%s' "$prior_attempt_context"
		_dlw_first_pass_completion_contract
		return 0
	fi

	printf '%s' "$original_prompt"
	printf '%s' "$prior_attempt_context"
	_dlw_first_pass_completion_contract
	return 0
}

_dlw_hold_repeated_zero_output() {
	local issue_number="$1"
	local repo_slug="$2"
	local precomputed_comment_metrics="${3:-}"
	local comment_metrics=""
	local comments=""
	local ops=""
	local metrics_zero_count=""
	local chars=""
	local precomputed_zero_count=""

	comment_metrics="$precomputed_comment_metrics"
	[[ -n "$comment_metrics" ]] || comment_metrics=$(_dlw_comment_bloat_metrics "$issue_number" "$repo_slug")
	IFS=$'\t' read -r comments ops metrics_zero_count chars <<<"$comment_metrics"
	if [[ "${CLEAN_ROOM_COMMENT_EVIDENCE_ENABLED:-1}" == "1" && "$metrics_zero_count" =~ ^[0-9]+$ ]]; then
		precomputed_zero_count="$metrics_zero_count"
	fi

	if _dlw_comment_bloat_requires_clean_room "$issue_number" "$repo_slug" "$comment_metrics"; then
		echo "[dispatch_with_dedup] #${issue_number} in ${repo_slug}: bypassing repeated zero-output brief-rewrite hold for clean-room brief mode" >>"$LOGFILE"
		return 1
	fi

	local zero_count=""
	zero_count=$(_dlw_zero_output_evidence_count "$issue_number" "$repo_slug" "$precomputed_zero_count")
	[[ "$zero_count" =~ ^[0-9]+$ ]] || zero_count=0
	local hold_threshold="${ZERO_OUTPUT_BRIEF_REWRITE_HOLD_THRESHOLD:-4}"
	[[ "$hold_threshold" =~ ^[0-9]+$ ]] || hold_threshold=4

	if [[ "$zero_count" -lt "$hold_threshold" ]]; then
		return 1
	fi

	echo "[dispatch_with_dedup] Holding #${issue_number} in ${repo_slug}: ${zero_count} zero-output launches; applying dispatch infrastructure hold" >>"$LOGFILE"
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "needs-maintainer-review" \
		--remove-label "status:available" \
		--remove-label "status:queued" >/dev/null 2>&1 || true
	gh issue comment "$issue_number" --repo "$repo_slug" --body "<!-- dispatch-infrastructure-failure -->
## Dispatch infrastructure failure detected

This issue has accumulated ${zero_count} zero-output worker launches. The brief may still be valid; repeated setup/runtime failures must be diagnosed before another automatic dispatch.

Next action: fix or wait out the worker/runtime failure family, then approve and requeue the issue so pulse can reconsider it afresh." >/dev/null 2>&1 || true
	return 0
}

#######################################
# Pre-create a worker worktree so the worker can start coding immediately
# instead of spending 5-8 tool calls on worktree setup. Populates module-level
# worktree and optional continuation-transfer globals:
#   _DLW_WORKTREE_PATH    — absolute path on success, empty on failure
#   _DLW_WORKTREE_BRANCH  — branch name on success, empty on failure
#   _DLW_WORKTREE_REUSED  — 1 when an existing issue worktree was reused, else 0
#   _DLW_WORKTREE_TRANSFER_MODE and _DLW_WORKTREE_EXPECTED_OWNER_* — exact
#       registry owner snapshot for an explicitly validated continuation
# All are reset on entry so the orchestrator always sees the fresh state.
#
# Issue-linked branch naming (GH#19042):
#   Branch format: feature/auto-YYYYMMDD-HHMMSS-gh<issue_number>
#   The -gh<N> suffix enables cleanup traceability (pulse-cleanup.sh
#   regex gh[-]?([0-9]+)), dedup branch scanning, and worktree reuse.
#   Previously branches were timestamp-only (feature/auto-YYYYMMDD-HHMMSS)
#   making orphaned worktrees untraceable — 57 accumulated in 24h on one
#   machine (2.2 GB wasted).
#
# Reuse-before-create:
#   Before creating a new worktree, scans existing worktrees for one
#   already linked to this issue (branch contains gh<N>). If found,
#   resets it to latest main and returns it — preventing accumulation
#   of duplicate worktrees when the same issue is dispatched repeatedly.
#
# On failure, the worker falls back to creating its own via
# full-loop-helper.sh.
#
# GH#18671: ANSI stripping — strip CSI sequences from worktree-helper.sh
# output before path extraction to avoid phantom directory suffixes.
#
# Arguments: issue_number, repo_path
#######################################
###############################################################################
# Restore gitignored dependencies (node_modules) in a worktree.
#
# Git worktrees only contain tracked files. Directories like node_modules/
# are gitignored, so they never appear in worktrees — even when the
# canonical repo has them installed. If a project tool (e.g. .opencode/
# tool/session-rename.ts) imports from node_modules, the runtime crashes
# on startup: "Cannot find module '@opencode-ai/plugin'".
#
# This caused 100% worker failure rate: 15 of 27 open issues stuck in
# dispatch-fail loops, 9 falsely escalated to tier:thinking. Workers
# exited 0 with zero model activity because the tool-loading error
# prevented the session from starting.
#
# Fix: after creating or resetting a worktree, copy scoped node_modules from
# the canonical repo for package directories that have package.json tracked
# in git. Root node_modules can be multi-GB and block the pulse before worker
# spawn, so headless dispatch skips it by default unless explicitly enabled
# with WORKTREE_NODE_MODULES_RESTORE_ROOT_ENABLED=1.
#
# Arguments: worktree_path, repo_path
###############################################################################
_dlw_node_modules_restore_lock_dir() {
	local workspace_dir="${AIDEVOPS_WORKSPACE_DIR:-${HOME}/.aidevops/.agent-workspace}"
	printf '%s\n' "${workspace_dir}/tmp/worktree-node-modules-restore.lock.d"
	return 0
}

_dlw_node_modules_restore_acquire_lock() {
	local lock_dir="$1"
	local timeout_s="${WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S:-2}"
	local elapsed=0
	[[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s=2
	mkdir -p "${lock_dir%/*}" 2>/dev/null || return 1
	while ! mkdir "$lock_dir" 2>/dev/null; do
		if [[ -d "$lock_dir" ]]; then
			local lock_mtime="" now_epoch="" age_s=""
			lock_mtime=$(_file_mtime_epoch "$lock_dir")
			now_epoch=$(date +%s)
			age_s=$((now_epoch - lock_mtime))
			if ((age_s > 60)); then
				# Stale lock dirs contain a pid marker. rmdir fails on that
				# non-empty directory; retrying immediately without changing
				# state spins pulse-wrapper children before worker_spawn.
				rm -rf "$lock_dir" 2>/dev/null || true
				continue
			fi
		fi
		if ((elapsed >= timeout_s * 10)); then
			return 1
		fi
		sleep 0.1
		elapsed=$((elapsed + 1))
	done
	printf '%s\n' "$$" >"${lock_dir}/pid" 2>/dev/null || true
	return 0
}

_dlw_node_modules_restore_release_lock() {
	local lock_dir="$1"
	rm -f "${lock_dir}/pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

_dlw_remove_generated_root_node_tool_link() {
	local worktree_path="$1"
	local repo_path="$2"
	local _src_bin="${repo_path}/node_modules/.bin"
	local _dst_bin="${worktree_path}/node_modules/.bin"
	local _link_target=""
	[[ -L "$_dst_bin" ]] || return 0
	_link_target=$(readlink "$_dst_bin" 2>/dev/null) || return 0
	[[ "$_link_target" == "$_src_bin" ]] || return 0
	rm -f "$_dst_bin" 2>/dev/null || return 0
	echo "[dispatch_with_dedup] Removed generated cross-boundary node_modules/.bin link from ${worktree_path}" >>"$LOGFILE"
	return 0
}

_dlw_restore_worktree_deps() {
	local worktree_path="$1"
	local repo_path="$2"

	[[ -z "$worktree_path" || -z "$repo_path" ]] && return 0
	[[ ! -d "$worktree_path" || ! -d "$repo_path" ]] && return 0
	[[ "${WORKTREE_NODE_MODULES_RESTORE_ENABLED:-1}" == "1" ]] || return 0

	local _lock_dir=""
	_lock_dir=$(_dlw_node_modules_restore_lock_dir)
	if ! _dlw_node_modules_restore_acquire_lock "$_lock_dir"; then
		echo "[dispatch_with_dedup] Skipping node_modules restore for ${worktree_path}: another restore is active" >>"$LOGFILE"
		return 0
	fi

	# Find directories in the worktree that have a package.json but are
	# missing node_modules. Only check top-level and one level deep —
	# deeper nesting is unlikely and find is expensive.
	local _pkg_dir=""
	local _restored=0
	local _max_dirs="${WORKTREE_NODE_MODULES_RESTORE_MAX_DIRS:-2}"
	local _restore_root="${WORKTREE_NODE_MODULES_RESTORE_ROOT_ENABLED:-0}"
	[[ "$_max_dirs" =~ ^[0-9]+$ ]] || _max_dirs=2
	while IFS= read -r _pkg_dir; do
		if ((_restored >= _max_dirs)); then
			break
		fi
		local _dir=""
		_dir=$(dirname "$_pkg_dir") || continue
		local _rel_dir=""
		_rel_dir="${_dir#"$worktree_path"}" || continue
		# _rel_dir is now e.g. "/.opencode" or "" (for root package.json)
		if [[ -z "$_rel_dir" && "$_restore_root" != "1" ]]; then
			_dlw_remove_generated_root_node_tool_link "$worktree_path" "$repo_path"
			echo "[dispatch_with_dedup] Skipping root node_modules restore for ${worktree_path} (set WORKTREE_NODE_MODULES_RESTORE_ROOT_ENABLED=1 to enable)" >>"$LOGFILE"
			continue
		fi
		local _src_nm="${repo_path}${_rel_dir}/node_modules"
		local _dst_nm="${worktree_path}${_rel_dir}/node_modules"
		if [[ -d "$_src_nm" && ! -d "$_dst_nm" ]]; then
			# t2889: fast_cp uses APFS clonefile / btrfs reflink CoW
			# where available — sub-second copy, near-zero disk delta.
			fast_cp "$_src_nm" "$_dst_nm" 2>/dev/null || true
			_restored=$((_restored + 1))
			echo "[dispatch_with_dedup] Restored node_modules: ${_rel_dir:-/} ($(du -sh "$_dst_nm" 2>/dev/null | cut -f1))" >>"$LOGFILE"
		fi
	done < <(find "$worktree_path" -maxdepth 3 -name "package.json" -not -path "*/node_modules/*" 2>/dev/null)
	_dlw_node_modules_restore_release_lock "$_lock_dir"

	return 0
}

_dlw_prepare_existing_worktree() {
	local existing_path="$1"
	local repo_path="$2"
	local preserve_owner_state="${3:-0}"
	if [[ "$preserve_owner_state" == "1" ]]; then
		echo "[dispatch_with_dedup] Preserving reused worktree until its expected continuation owner transfers: ${existing_path}" >>"$LOGFILE"
		return 0
	fi

	local existing_status=""
	existing_status=$(git -C "$existing_path" status --porcelain 2>/dev/null || true)
	if [[ -n "$existing_status" ]]; then
		# A same-runner retry must resume staged, unstaged, and untracked edits.
		# Resetting here destroyed the only useful copy before GH#27138.
		echo "[dispatch_with_dedup] Preserving dirty existing worktree for same-runner resume: ${existing_path}" >>"$LOGFILE"
		return 0
	fi

	local main_branch=""
	main_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
	main_branch="${main_branch:-main}"
	local ahead_count=""
	ahead_count=$(git -C "$existing_path" rev-list --count "origin/${main_branch}..HEAD" 2>/dev/null || true)
	if [[ ! "$ahead_count" =~ ^[0-9]+$ ]]; then
		echo "[dispatch_with_dedup] Preserving existing worktree because ahead state is unverified: ${existing_path}" >>"$LOGFILE"
		return 0
	fi
	if [[ "$ahead_count" -gt 0 ]]; then
		echo "[dispatch_with_dedup] Preserving ahead existing worktree for same-runner resume: ${existing_path} (ahead=${ahead_count})" >>"$LOGFILE"
		return 0
	fi

	# Only clean, verified zero-ahead retries restart from the default branch.
	git -C "$existing_path" checkout -- . 2>/dev/null || true
	git -C "$existing_path" clean -fd 2>/dev/null || true
	git -C "$existing_path" reset --hard "origin/${main_branch}" 2>/dev/null || true
	return 0
}

_dlw_capture_reused_worktree_owner() {
	local issue_number="$1"
	local worktree_path="$2"
	declare -F check_worktree_owner >/dev/null 2>&1 || return 1

	local owner_info=""
	owner_info=$(check_worktree_owner "$worktree_path" 2>/dev/null || true)
	[[ -n "$owner_info" ]] || return 1

	IFS='|' read -r _DLW_WORKTREE_EXPECTED_OWNER_PID \
		_DLW_WORKTREE_EXPECTED_OWNER_SESSION \
		_DLW_WORKTREE_EXPECTED_OWNER_BATCH \
		_DLW_WORKTREE_EXPECTED_OWNER_TASK \
		_DLW_WORKTREE_EXPECTED_OWNER_CREATED_AT <<<"$owner_info"
	_DLW_WORKTREE_TRANSFER_MODE="continuation"
	echo "[dispatch_with_dedup] Captured expected registry owner for #${issue_number} continuation without replacing it: ${worktree_path}" >>"$LOGFILE"
	return 0
}

_dlw_claim_unowned_reused_worktree() {
	local issue_number="$1"
	local worktree_path="$2"
	local branch="$3"
	local session_id="dispatch-precreate-${issue_number}"

	if ! declare -F claim_worktree_ownership >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Refusing reused worktree without an atomic owner claim for #${issue_number}: ${worktree_path}" >>"$LOGFILE"
		return 1
	fi
	if ! claim_worktree_ownership "$worktree_path" "$branch" \
		--task "$issue_number" --session "$session_id" 2>/dev/null; then
		echo "[dispatch_with_dedup] Atomic owner claim rejected for reused worktree #${issue_number}: ${worktree_path}" >>"$LOGFILE"
		return 1
	fi
	return 0
}

_dlw_precreate_worktree() {
	local issue_number="$1"
	local repo_path="$2"
	_DLW_WORKTREE_PATH=""
	_DLW_WORKTREE_BRANCH=""
	_DLW_WORKTREE_REUSED=0
	_DLW_WORKTREE_TRANSFER_MODE=""
	_DLW_WORKTREE_EXPECTED_OWNER_PID=""
	_DLW_WORKTREE_EXPECTED_OWNER_SESSION=""
	_DLW_WORKTREE_EXPECTED_OWNER_BATCH=""
	_DLW_WORKTREE_EXPECTED_OWNER_TASK=""
	_DLW_WORKTREE_EXPECTED_OWNER_CREATED_AT=""
	local _precreate_session="dispatch-precreate-${issue_number}"

	local _wt_helper="${SCRIPT_DIR}/worktree-helper.sh"
	if [[ ! -x "$_wt_helper" || ! -d "$repo_path" ]]; then
		return 0
	fi

	# --- Reuse check: scan for an existing worktree for this issue ---
	# Prevents accumulation of multiple dead worktrees when the same issue
	# is dispatched repeatedly (GH#19042). Matches branch names containing
	# gh<N> or gh-<N> (the pattern used by this function and cleanup regex).
	local _existing_path="" _existing_branch=""
	local _wt_line=""
	while IFS= read -r _wt_line; do
		local _wt_p="" _wt_b=""
		_wt_p=$(printf '%s' "$_wt_line" | awk '{print $1}') || _wt_p=""
		_wt_b=$(printf '%s' "$_wt_line" | awk '{print $3}' | sed 's/^\[//;s/\]$//') || _wt_b=""
		# Match branches with embedded issue number: gh19014 or gh-19014
		if [[ "$_wt_b" =~ gh-?${issue_number}([^0-9]|$) && -d "$_wt_p" ]]; then
			_existing_path="$_wt_p"
			_existing_branch="$_wt_b"
			break
		fi
	done < <(git -C "$repo_path" worktree list 2>/dev/null)

	if [[ -n "$_existing_path" ]]; then
		_DLW_WORKTREE_PATH="$_existing_path"
		_DLW_WORKTREE_BRANCH="$_existing_branch"
		_DLW_WORKTREE_REUSED=1
		local _has_continuation_owner=0
		if _dlw_capture_reused_worktree_owner "$issue_number" "$_DLW_WORKTREE_PATH"; then
			_has_continuation_owner=1
		elif ! _dlw_claim_unowned_reused_worktree "$issue_number" "$_DLW_WORKTREE_PATH" "$_DLW_WORKTREE_BRANCH"; then
			return 1
		fi
		_dlw_prepare_existing_worktree "$_existing_path" "$repo_path" "$_has_continuation_owner"
		# Restore gitignored deps that git clean -fd just wiped
		_dlw_restore_worktree_deps "$_DLW_WORKTREE_PATH" "$repo_path"
		echo "[dispatch_with_dedup] Reusing existing worktree for #${issue_number}: ${_DLW_WORKTREE_PATH} (branch: ${_DLW_WORKTREE_BRANCH})" >>"$LOGFILE"
		return 0
	fi

	# --- Create new worktree with issue-linked branch name ---
	# Format: feature/auto-YYYYMMDD-HHMMSS-gh<N>
	# The -gh<N> suffix enables:
	#   1. pulse-cleanup.sh crash classification (regex: gh[-]?([0-9]+))
	#   2. dispatch-dedup-layers.sh remote branch scan (regex: (t|gh-?)N)
	#   3. Reuse check above on subsequent dispatches for the same issue
	# Without it, orphaned worktrees are untraceable and accumulate (57
	# observed on one machine in 24h, 2.2 GB wasted).
	local _branch _wt_output=""
	_branch="feature/auto-$(date +%Y%m%d-%H%M%S)-gh${issue_number}"
	# Run from repo_path — worktree-helper.sh uses git commands that need
	# to be inside the repo. The pulse-wrapper's cwd is typically / (launchd).
	_wt_output=$(cd "$repo_path" && WORKTREE_NODE_MODULES_RESTORE_ENABLED=0 "$_wt_helper" add "$_branch" 2>&1) || true
	_wt_output=$(printf '%s' "$_wt_output" | sed $'s/\x1b\\[[0-9;]*m//g')
	local _path _path_source="porcelain"
	_path=$(_dlw_worktree_path_for_branch "$repo_path" "$_branch") || _path=""
	if [[ -z "$_path" ]]; then
		_path_source="helper-output"
		_path=$(_dlw_extract_worktree_path_from_output "$_wt_output") || _path=""
	fi
	echo "[dispatch_with_dedup] Worktree path resolution for #${issue_number}: source=${_path_source} branch=${_branch} path='${_path:-<empty>}' exists=$([[ -n "$_path" && -d "$_path" ]] && printf '1' || printf '0')" >>"$LOGFILE"
	if [[ -n "$_path" && -d "$_path" ]]; then
		_DLW_WORKTREE_PATH="$_path"
		_DLW_WORKTREE_BRANCH="$_branch"
		if declare -F register_worktree >/dev/null 2>&1; then
			register_worktree "$_DLW_WORKTREE_PATH" "$_DLW_WORKTREE_BRANCH" \
				--task "$issue_number" \
				--session "$_precreate_session" 2>/dev/null || true
		fi
		# Restore gitignored deps (node_modules) that git doesn't track
		_dlw_restore_worktree_deps "$_DLW_WORKTREE_PATH" "$repo_path"
		echo "[dispatch_with_dedup] Pre-created worktree for #${issue_number}: ${_DLW_WORKTREE_PATH} (branch: ${_DLW_WORKTREE_BRANCH})" >>"$LOGFILE"
	else
		# GH#18671: emit the raw extracted string on failure so future
		# regressions in path parsing are visible in the log. Previously
		# this message gave no diagnostic — 247 failures accumulated in
		# a single pulse.log before the root cause was found.
		# t2981: return 1 so the caller can skip dispatch instead of
		# falling back to the canonical repo on the default branch.
		echo "[dispatch_with_dedup] Warning: worktree pre-creation failed for #${issue_number} — dispatch will be skipped this cycle (extracted: '${_path:-<empty>}', wt_helper stdout head: '${_wt_output:0:120}')" >>"$LOGFILE"
		return 1
	fi
	return 0
}

_dlw_worktree_path_for_branch() {
	local repo_path="$1"
	local branch_name="$2"
	local _path=""
	_path=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null | awk -v branch="refs/heads/${branch_name}" '/^worktree / { path = substr($0, 10) } /^branch / { line_branch = substr($0, 8); if (line_branch == branch) { print path; exit } }') || _path=""
	printf '%s' "$_path"
	return 0
}

_dlw_extract_worktree_path_from_output() {
	local wt_output="$1"
	local _path=""
	_path=$(printf '%s' "$wt_output" | awk '/^Path:[[:space:]]*\// { sub(/^Path:[[:space:]]*/, ""); print; exit } /^[[:space:]]*cd[[:space:]]+\// { sub(/^[[:space:]]*cd[[:space:]]+/, ""); print; exit } /^Created worktree at[[:space:]]*\// { sub(/^Created worktree at[[:space:]]*/, ""); print; exit }') || _path=""
	printf '%s' "$_path"
	return 0
}

#######################################
# Pre-warm OpenCode DB to trigger migration + skill-dedup BEFORE nohup
# launch (t2758). Per-worker DB isolation (GH#17549) means each worker
# hits cold-start fresh — every isolated DB must run the one-time SQLite
# migration + 12-skill-dedup on first opencode invocation. That takes
# 10-20s and creates a vulnerability window where signals can kill the
# worker before a session is created. Running opencode --version against
# the pre-created isolated dir completes migration outside the timed
# dispatch window. The pre-warmed dir is passed to headless-runtime-helper.sh
# via AIDEVOPS_WORKER_PREWARM_DIR so it is reused instead of a fresh mktemp.
# Warm-up failure is non-fatal: dispatch continues unmodified (headless-
# runtime-helper.sh falls back to its normal mktemp path).
#
# Sets module-level global:
#   _DLW_PREWARM_DIR — absolute path on success, empty on failure/skip
#
# Arguments: worker_log (path to append lifecycle messages)
#######################################
_dlw_prewarm_opencode_db() {
	local worker_log="$1"
	_DLW_PREWARM_DIR=""

	command -v opencode >/dev/null 2>&1 || return 0

	_DLW_PREWARM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-worker-auth.XXXXXX") || { _DLW_PREWARM_DIR=""; return 0; }
	mkdir -p "${_DLW_PREWARM_DIR}/opencode"
	{
		echo "[lifecycle] opencode_warm_start pid=$$"
		if XDG_DATA_HOME="$_DLW_PREWARM_DIR" timeout "${OPENCODE_PREWARM_TIMEOUT_SECONDS:-90}" opencode --version >/dev/null 2>&1; then
			echo "[lifecycle] opencode_warm_done pid=$$"
		else
			echo "[lifecycle] WARN opencode warm-up failed or timed out — fallback to cold-start pid=$$"
			rm -rf "$_DLW_PREWARM_DIR" 2>/dev/null || true
			_DLW_PREWARM_DIR=""
		fi
	} >>"$worker_log" 2>&1
	return 0
}

#######################################
# Renew the dispatcher's prelaunch lease before the potentially slow OpenCode
# database warm-up. The worker renews it again after process start; this renewal
# closes the gap between worktree preparation and that worker-side transition.
# Arguments: issue_number repo_slug session_key worker_log
#######################################
_dlw_renew_prelaunch_lease() {
	local issue_number="$1"
	local repo_slug="$2"
	local session_key="$3"
	local worker_log="$4"
	local prewarm_timeout="${OPENCODE_PREWARM_TIMEOUT_SECONDS:-90}"
	local lease_ttl="${AIDEVOPS_DISPATCH_PREWARM_LEASE_TTL:-}"

	if [[ -z "${_claim_lease_token:-}" ]]; then
		return 0
	fi
	[[ "$prewarm_timeout" =~ ^[0-9]+$ ]] || prewarm_timeout=90
	[[ "$lease_ttl" =~ ^[0-9]+$ ]] || lease_ttl=$((prewarm_timeout + 60))

	printf '[lifecycle] dispatcher_prelaunch_lease_renew_start session=%s pid=%s\n' \
		"$session_key" "$$" >>"$worker_log"
	if ! AIDEVOPS_DEVICE_ID="${_claim_lease_device:-${AIDEVOPS_DEVICE_ID:-}}" \
		"${SCRIPT_DIR}/dispatch-claim-helper.sh" transition prelaunch "$issue_number" \
		"$repo_slug" "$_claim_lease_token" "$session_key" "$lease_ttl" \
		>/dev/null 2>&1; then
		printf '[lifecycle] WARN dispatcher prelaunch lease renewal failed before OpenCode warm-up session=%s pid=%s\n' \
			"$session_key" "$$" >>"$worker_log"
		return 1
	fi
	printf '[lifecycle] dispatcher_prelaunch_lease_renew_done session=%s pid=%s\n' \
		"$session_key" "$$" >>"$worker_log"
	return 0
}

_dlw_prepare_opencode_db() {
	local issue_number="$1"
	local repo_slug="$2"
	local session_key="$3"
	local worker_log="$4"

	_dlw_renew_prelaunch_lease "$issue_number" "$repo_slug" "$session_key" "$worker_log" || return 1
	_dlw_prewarm_opencode_db "$worker_log"
	return 0
}

#######################################
# Return 0 when a Linux systemd user manager is available for transient
# services. `setsid` detaches workers from the pulse process group, but it
# does NOT move them out of the systemd service cgroup. On systemd pulse
# timers, long-lived children therefore remain visible as leftovers after the
# oneshot exits (GH#23073). A transient user service gives each worker an
# intentional lifecycle owner outside aidevops-supervisor-pulse.service.
_dlw_systemd_user_service_available() {
	[[ "${AIDEVOPS_SKIP_SYSTEMD_WORKER_SERVICE:-0}" == "1" ]] && return 1
	[[ "$(uname -s 2>/dev/null || printf '%s' unknown)" == "Linux" ]] || return 1
	command -v systemd-run >/dev/null 2>&1 || return 1
	command -v systemctl >/dev/null 2>&1 || return 1
	systemctl --user status >/dev/null 2>&1 || return 1
	return 0
}

_dlw_systemd_unit_name() {
	local unit_prefix="$1"
	local issue_number="$2"
	local suffix="${RANDOM:-0}"
	printf '%s-%s-%s-%s' "$unit_prefix" "${issue_number:-unknown}" "$$" "$suffix"
	return 0
}

_dlw_systemd_snapshot() {
	local unit_name="$1"
	local state_file="$2"
	local snapshot=""

	snapshot=$(systemctl --user show "$unit_name" \
		-p Id -p MainPID -p ActiveState -p SubState \
		-p ExecMainCode -p ExecMainStatus -p Result 2>/dev/null || true)
	printf 'Unit=%s\n%s\n' "$unit_name" "$snapshot" >"$state_file"
	printf '%s\n' "$snapshot"
	return 0
}

_dlw_systemd_wait_stable() {
	local unit_name="$1"
	local issue_number="$2"
	local state_file="$3"
	local expected_pid="$4"
	local attempts="${DLW_SYSTEMD_STABILITY_ATTEMPTS:-3}"
	local wait_i=0 stable_count=0 snapshot="" main_pid="" active_state="" sub_state=""
	local exec_main_code="" exec_main_status="" result="" key="" value=""
	local poll_seconds="${DLW_SYSTEMD_STABILITY_POLL_SECONDS:-0.2}"

	[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=3
	[[ "$poll_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || poll_seconds="0.2"
	while [[ "$wait_i" -lt "$attempts" ]]; do
		snapshot=$(_dlw_systemd_snapshot "$unit_name" "$state_file")
		main_pid=""
		active_state=""
		sub_state=""
		exec_main_code="" exec_main_status="" result=""
		while IFS='=' read -r key value || [[ -n "$key" ]]; do
			case "$key" in
				MainPID) main_pid="$value" ;;
				ActiveState) active_state="$value" ;;
				SubState) sub_state="$value" ;;
				ExecMainCode) exec_main_code="$value" ;;
				ExecMainStatus) exec_main_status="$value" ;;
				Result) result="$value" ;;
			esac
		done <<<"$snapshot"

		if [[ "$active_state" == "failed" || "$active_state" == "inactive" ]]; then
			printf 'LaunchState=startup_failed\n' >>"$state_file"
			echo "[dispatch_worker_launch] systemd startup_failed unit=${unit_name} issue=${issue_number} MainPID=${main_pid:-0} ExecMainCode=${exec_main_code:-unknown} ExecMainStatus=${exec_main_status:-unknown} Result=${result:-unknown} state=${active_state:-unknown}/${sub_state:-unknown}" >>"$LOGFILE"
			return 2
		fi

		if [[ "$main_pid" == "$expected_pid" && "$active_state" == "active" && "$sub_state" == "running" ]]; then
			stable_count=$((stable_count + 1))
		else
			stable_count=0
		fi
		wait_i=$((wait_i + 1))
		[[ "$stable_count" -ge "$attempts" ]] && {
			printf 'LaunchState=worker_ready\n' >>"$state_file"
			return 0
		}
		sleep "$poll_seconds"
	done

	printf 'LaunchState=pid_observed\n' >>"$state_file"
	return 3
}

_dlw_systemd_resolve_main_pid() {
	local unit_name="$1"
	local issue_number="$2"
	local state_file="${3:-${TMPDIR:-/tmp}/aidevops-systemd-state.$$}"
	local wait_i=0 snapshot="" main_pid="" active_state="" sub_state="" key="" value=""

	while [[ "$wait_i" -lt 15 ]]; do
		snapshot=$(_dlw_systemd_snapshot "$unit_name" "$state_file")
		main_pid=""
		active_state=""
		sub_state=""
		while IFS='=' read -r key value || [[ -n "$key" ]]; do
			case "$key" in
				MainPID)
					main_pid="$value"
					;;
				ActiveState)
					active_state="$value"
					;;
				SubState)
					sub_state="$value"
					;;
			esac
		done <<<"$snapshot"

		if [[ "$main_pid" =~ ^[1-9][0-9]*$ ]]; then
			echo "[dispatch_worker_launch] WARNING: systemd worker PID handoff missing for unit ${unit_name}; resolved MainPID=${main_pid} state=${active_state:-unknown}/${sub_state:-unknown} via systemctl, not launching fallback" >>"$LOGFILE"
			local stable_rc=0
			if _dlw_systemd_wait_stable "$unit_name" "$issue_number" "$state_file" "$main_pid"; then
				printf '%s\n' "$main_pid"
				return 0
			else
				stable_rc=$?
			fi
			return "$stable_rc"
		fi

		case "${active_state:-unknown}" in
			inactive|failed)
				echo "[dispatch_worker_launch] systemd unit ${unit_name} has no live MainPID state=${active_state:-unknown}/${sub_state:-unknown}; falling back to setsid/nohup for #${issue_number}" >>"$LOGFILE"
				return 1
				;;
		esac

		sleep 0.2
		wait_i=$((wait_i + 1))
	done

	echo "[dispatch_worker_launch] ERROR: systemd-run launched ${unit_name} for #${issue_number} but no child PID or live MainPID was reported" >>"$LOGFILE"
	return 1
}

_dlw_exec_systemd_user_service() {
	local unit_prefix="$1"
	local worker_log="$2"
	local issue_number="$3"
	shift 3
	local state_file="${_DLW_SYSTEMD_STATE_FILE:-${TMPDIR:-/tmp}/aidevops-systemd-state.$$}"

	local pid_file=""
	pid_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-systemd-worker.XXXXXX") || return 1
	rm -f "$pid_file" 2>/dev/null || true

	local unit_name=""
	unit_name=$(_dlw_systemd_unit_name "$unit_prefix" "$issue_number")
	local runner_script
	# shellcheck disable=SC2016  # Expanded by the child bash launched by systemd-run.
	runner_script='
		_dlw_systemd_child() {
			local pid_file="$1" out_log="$2"
			shift 2
			printf "%s\n" "$$" >"$pid_file" 2>/dev/null || true
			exec "$@" </dev/null >>"$out_log" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-
		}
		_dlw_systemd_child "$@"
	'

	if ! systemd-run --user --unit="$unit_name" --collect --quiet \
		--description="aidevops worker ${issue_number:-unknown}" \
		/bin/bash -lc "$runner_script" _ "$pid_file" "$worker_log" "$@" \
		>/dev/null 2>>"$LOGFILE"; then
		rm -f "$pid_file" 2>/dev/null || true
		return 1
	fi

	local wait_i=0 service_pid=""
	while [[ "$wait_i" -lt 25 ]]; do
		if [[ -s "$pid_file" ]]; then
			read -r service_pid <"$pid_file" || service_pid=""
			break
		fi
		sleep 0.2
		wait_i=$((wait_i + 1))
	done
	rm -f "$pid_file" 2>/dev/null || true

	if [[ "$service_pid" =~ ^[0-9]+$ ]]; then
		echo "[dispatch_worker_launch] systemd unit ${unit_name} reported child PID=${service_pid} for #${issue_number}" >>"$LOGFILE"
		local stable_rc=0
		if _dlw_systemd_wait_stable "$unit_name" "$issue_number" "$state_file" "$service_pid"; then
			printf '%s\n' "$service_pid"
			return 0
		else
			stable_rc=$?
		fi
		return "$stable_rc"
	fi

	_dlw_systemd_resolve_main_pid "$unit_name" "$issue_number" "$state_file"
	return $?
}

_dlw_handle_systemd_launch_failure() {
	local systemd_rc="$1"
	local systemd_state_file="$2"
	local worker_log="$3"
	local issue_number="$4"

	if [[ "$systemd_rc" -ne 2 && "$systemd_rc" -ne 3 ]]; then
		echo "[dispatch_worker_launch] WARNING: systemd-run worker launch unresolved for #${issue_number}; falling back to setsid/nohup" >>"$LOGFILE"
		return 0
	fi

	if [[ -f "$systemd_state_file" ]]; then
		{
			if [[ "$systemd_rc" -eq 2 ]]; then
				printf '[systemd-launch] classification=crash_during_startup\n'
			else
				printf '[systemd-launch] classification=readiness_unconfirmed\n'
			fi
			cat "$systemd_state_file"
		} >>"$worker_log"
	fi
	echo "[dispatch_worker_launch] ERROR: systemd worker for #${issue_number} did not reach durable readiness (rc=${systemd_rc}); duplicate fallback suppressed" >>"$LOGFILE"
	return 1
}

# Execute a worker command via systemd-run (Linux user services) or setsid +
# nohup fallback, detaching it from the pulse's process group (t2757) and, on
# systemd, from the pulse oneshot cgroup (GH#23073). Without this, workers
# either die with the pulse cgroup or survive as ambiguous leftover children.
#
# macOS ships /usr/bin/setsid on recent versions (12+). Older macOS or
# systems without setsid fall back to nohup-only with a log warning.
#
# Arguments:
#   $1 - worker_log (path for stdout/stderr redirection)
#   $2 - issue_number (for log messages)
#   $3... - the worker command to execute
# Stdout: worker PID
#######################################
_dlw_exec_detached() {
	local worker_log="$1"
	local issue_number="$2"
	shift 2
	local -a worker_command=(
		env
		AIDEVOPS_GH_PR_LIST_CACHE_DISABLE=1
		PULSE_PR_LIST_PROVIDER_CACHE_DISABLE=1
		"$@"
	)
	# GH#26241: do not blanket-disable AIDEVOPS_GH_PR_VIEW_CACHE for workers.
	# Pulse now uses a stable TTL-scoped PR view cache, and mutation-sensitive
	# merge/update paths set AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 at the individual
	# read site. Keeping worker PR-view reads cacheable avoids a cold-cache burst
	# from every detached worker while preserving fresh reads where correctness
	# requires bypassing cache.

	# t2814 (Phase 3, fix #3): Close inherited file descriptors >2 before
	# exec to prevent FD leak from the pulse parent into the worker. The
	# pulse accumulates FDs over its lifetime (gh API curl handles, log
	# files, sqlite handles, temp files) and without explicit closure the
	# worker inherits all of them. Suspected (but unconfirmed) cause of
	# `EMFILE` early-exit cluster on long-running pulse instances. Cheap
	# insurance — `N>&-` is a no-op when FD N is not open.
	#
	# Bash 3.2 compatible: explicit numeric FDs (no `{fd}>&-` syntax which
	# requires bash 4+). Covers FDs 3-9 which is the practical range a
	# parent shell + sourced helpers would have inherited via redirections,
	# `exec` re-opens, or `coproc`. Higher FDs (10+) are rare in this
	# codebase and can be added if measurement justifies it.

	local worker_pid systemd_rc=1
	local systemd_state_file="${worker_log}.systemd-launch"
	if _dlw_systemd_user_service_available; then
		if worker_pid=$(_DLW_SYSTEMD_STATE_FILE="$systemd_state_file" _dlw_exec_systemd_user_service "aidevops-worker" "$worker_log" "$issue_number" "${worker_command[@]}"); then
			echo "[dispatch_worker_launch] Issue #${issue_number}: worker PID=$worker_pid launched via systemd-run transient user service outside pulse cgroup" >>"$LOGFILE"
		else
			systemd_rc=$?
			if ! _dlw_handle_systemd_launch_failure "$systemd_rc" "$systemd_state_file" "$worker_log" "$issue_number"; then
				return 1
			fi
		fi
	fi

	if [[ -z "${worker_pid:-}" ]] && command -v setsid >/dev/null 2>&1; then
		setsid nohup "${worker_command[@]}" </dev/null >>"$worker_log" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
		worker_pid="$!"
		# Log the detached PGID for diagnostics (should differ from pulse PGID)
		local worker_pgid="" pulse_pgid=""
		worker_pgid=$(ps -o pgid= -p "$worker_pid" 2>/dev/null | tr -d ' ')
		[[ -n "$worker_pgid" ]] || worker_pgid="unknown"
		pulse_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
		[[ -n "$pulse_pgid" ]] || pulse_pgid="unknown"
		echo "[dispatch_worker_launch] Issue #${issue_number}: worker PID=$worker_pid PGID=$worker_pgid (setsid detached from pulse PGID=$pulse_pgid; FDs 3-9 closed for t2814)" >>"$LOGFILE"
	elif [[ -z "${worker_pid:-}" ]]; then
		echo "[dispatch_worker_launch] ERROR: setsid missing — worker isolation broken; worker shares pulse PGID and will be killed on next pulse restart. Run: aidevops update (GH#21102)" >>"$LOGFILE"
		nohup "${worker_command[@]}" </dev/null >>"$worker_log" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
		worker_pid="$!"
	fi

	# t2814 (Phase 3, fix #2): Spawn-time exit monitoring. Fork a tiny
	# background watcher that polls the nohup'd PID for the first
	# DLW_EARLY_EXIT_WINDOW_SECONDS (default 20s) and, on early death,
	# appends a marker line to the worker log so the recovery path
	# (pulse-cleanup.sh:_post_launch_recovery_claim_released) can include
	# it in the CLAIM_RELEASED audit trail.
	#
	# The pulse subshell that called us exits long before the worker does
	# in the success case, so we cannot `wait` on the PID synchronously.
	# Instead, we fork-and-forget — the watcher itself uses setsid+nohup
	# so it survives pulse exit and self-terminates after the window
	# regardless of worker outcome.
	#
	# Cheap: 5-iteration polling loop with `sleep 4` (~20s wall, near-zero
	# CPU). Bounded: never runs longer than the window. Idempotent: just
	# appends a marker; no global state.
	_dlw_spawn_early_exit_monitor "$worker_pid" "$worker_log" "$issue_number"

	# t3055/GH#21870: Spawn the parent-side lifecycle observer that polls the
	# detached worker PID until it terminates and emits a
	# `[lifecycle] worker_exited pid=N wait_status=M` line to the pulse log.
	# This is independent of the worker's own emit path (which lives in
	# headless-runtime-helper.sh::_invoke_opencode and only fires on
	# graceful, post-`wait` exits). The observer is the safety net for
	# every other termination mode (early exec failure, SIGKILL/OOM,
	# setsid-detached vanishing, watchdog kill before child trap installs).
	_dlw_spawn_lifecycle_observer "$worker_pid" "$issue_number" "$LOGFILE"

	printf '%s\n' "$worker_pid"
	return 0
}

# t2814 (Phase 3, fix #2): Background watcher that detects worker early-exit
# during the spawn window and writes a diagnostic marker to the worker log.
#
# Without this, the only signal that a worker died at startup is the
# absence of a process when `check_worker_launch` polls 15-20s later — at
# which point the exit code is reaped by init and lost. The marker bridges
# the diagnostic gap so the launch-recovery path can attribute the failure.
#
# Args:
#   $1 - worker_pid (PID returned by setsid/nohup launch)
#   $2 - worker_log (log file path; marker is appended here)
#   $3 - issue_number (for log message context)
# Side effects:
#   - Forks a detached `bash -c` subshell that runs for up to
#     ${DLW_EARLY_EXIT_WINDOW_SECONDS:-20} seconds.
#   - On early death, appends a `[t2814:early_exit]` line to worker_log.
# Returns: 0 always.
_dlw_spawn_early_exit_monitor() {
	local worker_pid="$1"
	local worker_log="$2"
	local issue_number="$3"
	local window="${DLW_EARLY_EXIT_WINDOW_SECONDS:-20}"
	local poll_interval="${DLW_EARLY_EXIT_POLL_SECONDS:-4}"

	# Defensive: skip if PID is not numeric (caller bug or test fixture)
	if [[ ! "$worker_pid" =~ ^[0-9]+$ ]]; then
		return 0
	fi

	# The monitor runs in its own detached process so it outlives the
	# pulse dispatch subshell. We pass argv via positional params to
	# avoid quoting hell with the inner bash -c body.
	local monitor_script
	# SC2016: variable expansion is intentional inside the inner `bash -c`
	# body, not in the outer shell. Single quotes are required so $1..$5
	# refer to the positional params passed to bash, not to this function.
	# The inner body wraps the params in `local` declarations inside a
	# helper function — this satisfies the pre-commit positional-parameter
	# linter (line 217 of pre-commit-hook.sh skips `local var=$N` lines)
	# and keeps the body resilient to argv-shift refactors.
	# shellcheck disable=SC2016
	monitor_script='
		_dlw_monitor_body() {
			local pid="$1" log="$2" issue="$3" window="$4" interval="$5"
			local elapsed=0 ts=""
			while [[ "$elapsed" -lt "$window" ]]; do
				if ! kill -0 "$pid" 2>/dev/null; then
					ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
					printf "[t2814:early_exit] worker PID %s for issue #%s exited within %ss spawn window at %s\n" "$pid" "$issue" "$elapsed" "$ts" >>"$log" 2>/dev/null || true
					return 0
				fi
				sleep "$interval"
				elapsed=$((elapsed + interval))
			done
			return 0
		}
		_dlw_monitor_body "$@"
	'

	if _dlw_systemd_user_service_available; then
		_dlw_exec_systemd_user_service "aidevops-worker-monitor" "/dev/null" "$issue_number" \
			bash -c "$monitor_script" _dlw_monitor \
			"$worker_pid" "$worker_log" "$issue_number" \
			"$window" "$poll_interval" \
			>/dev/null 2>&1 && return 0
	fi

	if command -v setsid >/dev/null 2>&1; then
		setsid nohup bash -c "$monitor_script" _dlw_monitor \
			"$worker_pid" "$worker_log" "$issue_number" \
			"$window" "$poll_interval" \
			</dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
	else
		nohup bash -c "$monitor_script" _dlw_monitor \
			"$worker_pid" "$worker_log" "$issue_number" \
			"$window" "$poll_interval" \
			</dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
	fi
	# Disown so any pulse parent shell EXIT trap that targets backgrounded
	# jobs cannot reach the monitor. setsid already detaches the PGID.
	disown 2>/dev/null || true
	return 0
}

# t3055 / GH#21870: Parent-side lifecycle observer for detached workers.
#
# Bug background: `_dlw_exec_detached` launches the worker via
# `setsid nohup ... &`, captures the PID, and the calling pulse process
# returns long before the worker terminates. The worker's OWN exit-line
# emit lives in `headless-runtime-helper.sh::_invoke_opencode` after the
# `wait "$worker_pid"` call, but only fires when the worker's wrapper
# script reaches that point. Workers that die earlier — exec failure,
# SIGKILL/OOM, immediate setsid death, watchdog kill before the
# wrapper's trap is installed — vanish without a `worker_exited` line,
# breaking post-mortem (canonical: PID 88900 on 2026-04-29 ~18:37Z).
#
# Fix: spawn a tiny detached watcher (mirrors _dlw_spawn_early_exit_monitor)
# that polls the worker PID and, the moment `kill -0` returns false,
# appends a `[lifecycle] worker_exited pid=N wait_status=M` line to the
# pulse log. The observer is the SAFETY NET — if the worker also emits
# its own line (the happy path), pulse.log will carry both, but `gap` in
# the empirical baseline check stays near zero either way.
#
# Why polling and not `wait`: the observer is forked from a setsid'd
# pulse subshell that exits immediately; it has no parent-child
# reaping relationship with the worker (different PGID). `wait` would
# return -1/ECHILD instantly. `kill -0` only checks process existence.
#
# Why no precise wait_status: a non-parent process cannot reap exit
# codes via `waitpid`. We emit `wait_status=unknown` on observer-side
# detection. The worker's own emit (when reached) carries the real
# status. The signal — that the worker died — is the value here.
#
# Bounded lifetime: the observer self-terminates after
# DLW_LIFECYCLE_OBSERVER_MAX_SECONDS (default 6h, matches
# HEADLESS_SANDBOX_TIMEOUT ceiling) so it cannot leak forever if the
# PID becomes irreapable.
#
# Args:
#   $1 - worker_pid (PID returned by setsid/nohup launch)
#   $2 - issue_number (for log message context)
#   $3 - logfile (absolute path; line is appended here — typically pulse.log)
# Returns: 0 always.
_dlw_spawn_lifecycle_observer() {
	local worker_pid="$1"
	local issue_number="$2"
	local logfile="$3"
	local max_seconds="${DLW_LIFECYCLE_OBSERVER_MAX_SECONDS:-21600}"
	local poll_interval="${DLW_LIFECYCLE_OBSERVER_POLL_SECONDS:-5}"

	# Defensive: skip if PID is not numeric (caller bug or test fixture)
	if [[ ! "$worker_pid" =~ ^[0-9]+$ ]]; then
		return 0
	fi
	if [[ -z "$logfile" ]]; then
		return 0
	fi

	# Inner body runs in a detached subshell and outlives the pulse cycle.
	# Positional args: pid, issue, log, max_seconds, interval.
	local observer_script
	# SC2016: variable expansion is intentional inside the inner `bash -c`
	# body, not in the outer shell. Mirrors the pattern used in
	# _dlw_spawn_early_exit_monitor above.
	# shellcheck disable=SC2016
	observer_script='
		_dlw_observer_body() {
			local pid="$1" issue="$2" log="$3" max_s="$4" interval="$5"
			local elapsed=0 ts="" reason="observed"
			while [[ "$elapsed" -lt "$max_s" ]]; do
				if ! kill -0 "$pid" 2>/dev/null; then
					ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
					printf "[INFO] [lifecycle] worker_exited pid=%s wait_status=unknown kill_reason=%s observer=parent issue=%s ts=%s\n" \
						"$pid" "$reason" "$issue" "$ts" >>"$log" 2>/dev/null || true
					return 0
				fi
				sleep "$interval"
				elapsed=$((elapsed + interval))
			done
			# Hit the max-lifetime ceiling without observing termination —
			# emit a diagnostic so the gap surfaces in audit, but do not
			# block. The watchdog and pulse-cleanup paths catch true zombies.
			ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
			printf "[WARN] [lifecycle] worker_observer_timeout pid=%s elapsed=%ss issue=%s ts=%s\n" \
				"$pid" "$elapsed" "$issue" "$ts" >>"$log" 2>/dev/null || true
			return 0
		}
		_dlw_observer_body "$@"
	'

	if _dlw_systemd_user_service_available; then
		_dlw_exec_systemd_user_service "aidevops-worker-observer" "/dev/null" "$issue_number" \
			bash -c "$observer_script" _dlw_observer \
			"$worker_pid" "$issue_number" "$logfile" \
			"$max_seconds" "$poll_interval" \
			>/dev/null 2>&1 && return 0
	fi

	if command -v setsid >/dev/null 2>&1; then
		setsid nohup bash -c "$observer_script" _dlw_observer \
			"$worker_pid" "$issue_number" "$logfile" \
			"$max_seconds" "$poll_interval" \
			</dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
	else
		nohup bash -c "$observer_script" _dlw_observer \
			"$worker_pid" "$issue_number" "$logfile" \
			"$max_seconds" "$poll_interval" \
			</dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
	fi
	disown 2>/dev/null || true
	return 0
}

#######################################
# Build the worker command and launch it via `nohup` (GH#17549).
# launchd runs pulse-wrapper with StartInterval=120s. When the wrapper
# exits after its dispatch cycle, bash sends SIGHUP to background jobs.
# `nohup` makes the worker immune to SIGHUP so it survives the parent's
# exit. The EXIT trap only releases the instance lock (no child killing).
#
# Delegates pre-warm to _dlw_prewarm_opencode_db and process-group
# detachment to _dlw_exec_detached.
#
# Arguments:
#   $1  - issue_number
#   $2  - repo_slug (owner/repo)
#   $3  - dispatch_title
#   $4  - issue_title
#   $5  - session_key
#   $6  - worker_log (path from _dlw_setup_worker_log)
#   $7  - prompt
#   $8  - repo_path
#   $9  - dispatch_model_tier (simple|standard|thinking)
#   $10 - selected_model (may be empty for auto-select)
#   $11 - worker_worktree_path (may be empty)
#   $12 - worker_worktree_branch (may be empty)
#   $13 - attempt_id (optional)
#   $14 - attempt_started_at (optional)
#   $15 - worktree transfer mode (empty|continuation)
#   $16-$20 - expected owner PID, session, batch, task, and created_at
# Stdout: worker PID
#######################################
_dlw_build_worker_title() {
	local issue_number="$1"
	local issue_title="$2"
	local dispatch_title="$3"
	local title="${issue_title:-${dispatch_title}}"

	if [[ -z "$issue_number" ]]; then
		printf '%s' "$title"
		return 0
	fi

	case "$title" in
		"Issue #${issue_number}" | "Issue #${issue_number}: "* | "Issue #${issue_number} - "* | \
			"#${issue_number}" | "#${issue_number}: "* | "#${issue_number} - "* | \
			"GH#${issue_number}" | "GH#${issue_number}: "* | "GH#${issue_number} - "*)
			printf '%s' "$title"
			return 0
			;;
	esac

	if [[ -z "$title" ]]; then
		printf 'Issue #%s' "$issue_number"
		return 0
	fi

	printf 'Issue #%s: %s' "$issue_number" "$title"
	return 0
}

#######################################
# Populate caller-scoped worker lineage variables before launch.
# Arguments:
#   $1 - session key
#######################################
_dlw_prepare_worker_lineage() {
	local session_key_arg="$1"
	local lineage_epoch=""
	lineage_epoch=$(date +%s 2>/dev/null || printf '0')
	parent_worker_id="${AIDEVOPS_WORKER_ID:-}"
	root_worker_id="${AIDEVOPS_ROOT_WORKER_ID:-}"
	correlation_id="${AIDEVOPS_CORRELATION_ID:-}"
	worker_id="worker:${session_key_arg}:$$:${lineage_epoch}:${RANDOM:-0}"
	[[ -n "$root_worker_id" ]] || root_worker_id="${parent_worker_id:-$worker_id}"
	[[ -n "$correlation_id" ]] || correlation_id="correlation:${root_worker_id}"
	if declare -F _emit_supervisor_dispatch_event >/dev/null 2>&1; then
		dispatch_event_id=$(_emit_supervisor_dispatch_event \
			"$worker_id" "$parent_worker_id" "$root_worker_id" "$correlation_id") || dispatch_event_id=""
	fi
	root_event_id="${AIDEVOPS_ROOT_EVENT_ID:-$dispatch_event_id}"
	return 0
}

_dlw_validate_worktree_for_launch() {
	local issue_number="$1"
	local worker_worktree_path="$2"
	if [[ -n "$worker_worktree_path" && -d "$worker_worktree_path" ]]; then
		return 0
	fi
	printf '[pulse-dispatch] worker launch skipped: worktree unavailable for #%s path=%s\n' \
		"$issue_number" "${worker_worktree_path:-missing}" >>"$LOGFILE"
	return 1
}

_dlw_append_node_tool_env() {
	local repo_path="$1"
	local node_tool_bin="${repo_path}/node_modules/.bin"
	[[ -d "$node_tool_bin" && ! -L "$node_tool_bin" ]] || return 0
	[[ "$node_tool_bin" != *:* && "$node_tool_bin" != *$'\n'* ]] || return 0
	# Expose only executable package entrypoints through PATH. Do not place a
	# canonical-checkout symlink inside the worktree or grant broad file access.
	worker_cmd+=(PATH="${node_tool_bin}:${PATH:-/usr/bin:/bin}")
	return 0
}

_dlw_append_trusted_release_env() {
	local trusted_priority="${_DLW_TRUSTED_ISSUE_PRIORITY:-}"
	local trusted_release_type="${_DLW_TRUSTED_RELEASE_TYPE:-}"
	local trusted_deploy_scope="${_DLW_TRUSTED_DEPLOY_SCOPE:-}"
	worker_cmd+=(AIDEVOPS_TRUSTED_ISSUE_PRIORITY="$trusted_priority")
	if [[ -n "$trusted_release_type" ]]; then
		worker_cmd+=(AIDEVOPS_RELEASE_INTENT_TRUSTED=1 AIDEVOPS_RELEASE_TYPE="$trusted_release_type" AIDEVOPS_RELEASE_DEPLOY_SCOPE="${trusted_deploy_scope:-incremental}")
	fi
	return 0
}

_dlw_append_worktree_transfer_env() {
	local transfer_mode="${_DLW_WORKTREE_TRANSFER_MODE:-}"
	local expected_owner_pid="${_DLW_WORKTREE_EXPECTED_OWNER_PID:-}"
	local expected_owner_session="${_DLW_WORKTREE_EXPECTED_OWNER_SESSION:-}"
	local expected_owner_batch="${_DLW_WORKTREE_EXPECTED_OWNER_BATCH:-}"
	local expected_owner_task="${_DLW_WORKTREE_EXPECTED_OWNER_TASK:-}"
	local expected_owner_created_at="${_DLW_WORKTREE_EXPECTED_OWNER_CREATED_AT:-}"
	[[ "$transfer_mode" == "continuation" ]] || return 0

	worker_cmd+=(
		AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE="$transfer_mode"
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID="$expected_owner_pid"
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION="$expected_owner_session"
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_BATCH="$expected_owner_batch"
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK="$expected_owner_task"
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT="$expected_owner_created_at"
	)
	return 0
}

#######################################
# Launch a worker process detached from the pulse process group.
# Stdout: worker PID
#######################################
_dlw_nohup_launch() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_title="$3"
	local issue_title="$4"
	local session_key="$5"
	local worker_log="$6"
	local prompt="$7"
	local repo_path="$8"
	local dispatch_model_tier="$9"
	local selected_model="${10}"
	local worker_worktree_path="${11}" worker_worktree_branch="${12}" attempt_id="${13:-}" attempt_started_at="${14:-}"
	[[ -n "$attempt_id" ]] || attempt_id=$(aidevops_generate_execution_id "attempt")
	[[ "$attempt_started_at" =~ ^[0-9]+$ ]] || attempt_started_at=$(_worker_attempt_start_marker)
	local parent_worker_id="" root_worker_id="" correlation_id="" worker_id="" dispatch_event_id="" root_event_id=""
	_dlw_prepare_worker_lineage "$session_key"

	_dlw_validate_worktree_for_launch "$issue_number" "$worker_worktree_path" || return 1

	# Use issue title as session title for searchable history, but keep the
	# issue marker at the beginning so Tabby tabs and OpenCode session search
	# group worker sessions by issue number.
	# Workers no longer need to call session-rename — the title is set at dispatch.
	local worker_title
	worker_title=$(_dlw_build_worker_title "$issue_number" "$issue_title" "$dispatch_title")

	# Renew the lease before pre-warm; the child renews again before canary.
	_dlw_prepare_opencode_db "$issue_number" "$repo_slug" "$session_key" "$worker_log" || return 1
	local worker_prewarm_dir="$_DLW_PREWARM_DIR"

	# Launch worker — headless-runtime-helper.sh handles model selection
	# when no --model is specified. Its choose_model() uses the routing
	# table/local override, then checks backoff/auth and rotates providers.
	local -a worker_cmd=(
		env
		HEADLESS=1
		FULL_LOOP_HEADLESS=true
		AIDEVOPS_SESSION_ORIGIN=worker
		AIDEVOPS_HEADLESS=true
		AIDEVOPS_WORKER_ID="$worker_id"
		AIDEVOPS_PARENT_WORKER_ID="$parent_worker_id"
		AIDEVOPS_ROOT_WORKER_ID="$root_worker_id"
		AIDEVOPS_CORRELATION_ID="$correlation_id"
		AIDEVOPS_ATTEMPT_ID="$attempt_id"
		AIDEVOPS_ATTEMPT_STARTED_AT="$attempt_started_at"
		AIDEVOPS_ROOT_EVENT_ID="$root_event_id"
		AIDEVOPS_PARENT_EVENT_ID="$dispatch_event_id"
		AIDEVOPS_CAUSATION_ID="$dispatch_event_id"
		WORKER_ISSUE_NUMBER="$issue_number"
		WORKER_REPO_SLUG="$repo_slug"
		WORKER_GITHUB_LOGIN="$self_login"
		AIDEVOPS_DISPATCH_LEASE_TOKEN="${_claim_lease_token:-}"
		AIDEVOPS_DISPATCH_LEASE_DEVICE="${_claim_lease_device:-}"
		AIDEVOPS_DISPATCH_TIER="$dispatch_model_tier"
		AIDEVOPS_DISPATCH_MODEL="$selected_model"
	)
	_dlw_append_node_tool_env "$repo_path"
	_dlw_append_trusted_release_env
	_dlw_append_worktree_transfer_env
	if _dlw_min_worker_floor_active; then
		worker_cmd+=(
			AIDEVOPS_MIN_WORKER_FLOOR_BYPASS_ACTIVE=1
		)
	fi
	# Pass worktree env vars only if pre-creation succeeded
	if [[ -n "$worker_worktree_path" ]]; then
		worker_cmd+=(
			WORKER_WORKTREE_PATH="$worker_worktree_path"
			WORKER_WORKTREE_BRANCH="$worker_worktree_branch"
		)
	fi
	# t2758: Pass pre-warmed DB dir to headless-runtime-helper.sh so it
	# reuses the already-migrated isolated dir instead of creating a fresh one.
	if [[ -n "$worker_prewarm_dir" ]]; then
		worker_cmd+=(AIDEVOPS_WORKER_PREWARM_DIR="$worker_prewarm_dir")
	fi
	worker_cmd+=(
		"$HEADLESS_RUNTIME_HELPER" run
		--role worker
		--session-key "$session_key"
		--dir "$worker_worktree_path"
		--tier "$dispatch_model_tier"
		--title "$worker_title"
		--prompt "$prompt"
	)
	if [[ -n "$selected_model" ]]; then
		# Dispatcher-selected models are initial preferences, not user-pinned
		# overrides. Let headless-runtime-helper.sh retry/rotate on transient
		# no-activity/provider failures while preserving explicit --model pins.
		worker_cmd+=(--initial-model "$selected_model")
	fi
	local bundle_agent
	bundle_agent=$(_dlw_bundle_agent_name "$repo_path" "$issue_title" "$prompt") || bundle_agent=""
	if [[ -n "$bundle_agent" ]]; then
		worker_cmd+=(--agent "$bundle_agent")
	fi

	_dlw_exec_detached "$worker_log" "$issue_number" "${worker_cmd[@]}"
	return 0
}

#######################################
# Transition a durably registered live worker from queued to in-progress.
#
# Args: issue_number, repo_slug, self_login, worker_pid
# Returns: 0=transition confirmed by mutation command, 1=worker/status unavailable
#######################################
_dlw_mark_worker_in_progress() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local worker_pid="$4"

	[[ "$worker_pid" =~ ^[0-9]+$ ]] || return 1
	if ! kill -0 "$worker_pid" 2>/dev/null; then
		echo "[dispatch_with_dedup] Worker registration for #${issue_number} has non-live PID ${worker_pid}; retaining status:queued for recovery" >>"$LOGFILE"
		return 1
	fi
	if ! declare -F set_issue_status >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Cannot transition #${issue_number} to status:in-progress: status helper unavailable" >>"$LOGFILE"
		return 1
	fi
	if ! set_issue_status "$issue_number" "$repo_slug" "in-progress" \
		--add-assignee "$self_login" >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Failed to transition registered worker #${issue_number} to status:in-progress; retaining queued recovery signal" >>"$LOGFILE"
		return 1
	fi
	echo "[dispatch_with_dedup] Registered live worker PID ${worker_pid} for #${issue_number}; transitioned status:queued to status:in-progress" >>"$LOGFILE"
	return 0
}

#######################################
# Post-launch bookkeeping: dispatch-ledger registration, the deterministic
# "Dispatching worker" comment on the issue, stagger delay, and claim-comment
# retention logging.
#
# Stagger (GH#17549): reduces SQLite write contention on opencode.db
# (busy_timeout=0). Without it, batches of 8+ workers all hit the DB
# simultaneously, causing SQLITE_BUSY → silent mid-turn death. The stagger
# happens after the dispatch comment is posted so a fast worker failure cannot
# publish CLAIM_RELEASED before the public "Dispatching worker" audit event.
#
# Dispatch comment (GH#15317): posted from the dispatcher, NOT from the
# worker LLM session. Previously, the worker was responsible for posting
# this comment — but workers could crash before posting, leaving no
# persistent signal. Without this signal, Layer 5 (has_dispatch_comment)
# had nothing to find, and the issue would be re-dispatched every pulse
# cycle. Evidence: webapp #2051 accumulated 29 DISPATCH_CLAIM comments
# over 6 hours because workers kept dying before posting.
#
# Claim comment retention (GH#17503): claim comments are NEVER deleted —
# they form the persistent audit trail and are respected as the primary
# dedup lock for 30 minutes. The deferred deletion that previously ran
# here (GH#17497) was the root cause of duplicate dispatches. Evidence:
# GH#17503 — 6 dispatches from marcusquinn + 1 from alex-solovyev,
# producing 2 duplicate PRs (#17512, #17513). This helper clears
# `_claim_comment_id` (dynamically-scoped from dispatch_with_dedup) once
# the retention message is logged so subsequent dispatches start fresh.
#
# Arguments: issue_number, repo_slug, self_login, worker_pid, session_key,
#            dispatch_tier, selected_model, worker_worktree_path
#######################################
_dlw_post_launch_hooks() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local worker_pid="$4"
	local session_key="$5"
	local dispatch_tier="$6"
	local selected_model="$7"
	local worker_worktree_path="${8:-}"
	local attempt_id="${9:-}"

	# Record in dispatch ledger (with tier telemetry)
	local ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	local ledger_registered=0
	if [[ -x "$ledger_helper" ]]; then
		if "$ledger_helper" register --session-key "$session_key" \
			--issue "$issue_number" --repo "$repo_slug" \
			--pid "$worker_pid" --tier "$dispatch_tier" \
			--model "$selected_model" --lease-token "${_claim_lease_token:-}" \
			--attempt-id "$attempt_id" \
			--device-id "${_claim_lease_device:-}" --worktree "$worker_worktree_path" 2>/dev/null; then
			ledger_registered=1
		else
			echo "[dispatch_with_dedup] Failed to register worker PID ${worker_pid} for #${issue_number}; retaining status:queued for recovery" >>"$LOGFILE"
		fi
	else
		echo "[dispatch_with_dedup] Dispatch ledger helper unavailable for #${issue_number}; retaining status:queued for recovery" >>"$LOGFILE"
	fi
	if [[ "$ledger_registered" -eq 1 ]]; then
		_dlw_mark_worker_in_progress "$issue_number" "$repo_slug" "$self_login" "$worker_pid" || true
	fi

	local dispatch_comment_body
	local display_model="${selected_model:-auto-select (round-robin)}"
	local aidevops_version="$AIDEVOPS_UNKNOWN_VERSION" opencode_version="$AIDEVOPS_UNKNOWN_VERSION"
	if declare -F aidevops_find_version >/dev/null 2>&1; then
		aidevops_version=$(aidevops_find_version 2>/dev/null || printf '%s' "$AIDEVOPS_UNKNOWN_VERSION")
	fi
	if declare -F _detect_opencode_version >/dev/null 2>&1; then
		opencode_version=$(_detect_opencode_version 2>/dev/null || printf '%s' "")
		opencode_version="${opencode_version:-$AIDEVOPS_UNKNOWN_VERSION}"
	fi
	dispatch_comment_body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
Dispatching worker (deterministic).
- **Worker PID**: ${worker_pid}
- **Model**: ${display_model}
- **Tier**: ${dispatch_tier}
- **Runner**: ${self_login}
- **aidevops**: $(_dlw_display_version_or_unknown "$aidevops_version")
- **OpenCode**: $(_dlw_display_version_or_unknown "$opencode_version")
- **Issue**: #${issue_number}
<!-- ops:end -->"
	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST --field body="$dispatch_comment_body" \
		>/dev/null 2>>"$LOGFILE" || {
		echo "[dispatch_with_dedup] Warning: failed to post deterministic dispatch comment for #${issue_number}" >>"$LOGFILE"
	}

	# _claim_comment_id is dynamically scoped from dispatch_with_dedup through
	# _dispatch_launch_worker into this helper — assignment without `local`
	# propagates up the stack, matching the pre-GH#18654 behavior.
	if [[ -n "$_claim_comment_id" ]]; then
		echo "[dispatch_with_dedup] Claim comment ${_claim_comment_id} retained for audit trail on #${issue_number} (GH#17503)" >>"$LOGFILE"
		_claim_comment_id=""
	fi

	local stagger_delay="${PULSE_DISPATCH_STAGGER_SECONDS:-8}"
	sleep "$stagger_delay"
	return 0
}

#######################################
# Hold dispatch when a reused worker branch repeatedly orphaned.
#
# The branch-specific check lives in dispatch-dedup-helper.sh so tests and
# ad-hoc diagnosis can exercise it directly. It runs after worktree
# pre-creation because only then do we know whether dispatch is reusing the same
# issue-linked branch or creating a fresh branch. A new branch therefore does
# not inherit an old branch's orphan count.
#
# Args: $1 = issue number, $2 = repo slug, $3 = worker worktree branch,
#       $4 = 1 when the branch was reused, 0 for a freshly-created branch,
#       $5 = TODO.md path for remote-child reconciliation (optional),
#       $6 = worker worktree path for orphan recovery probes (optional)
# Returns: exit 0 if dispatch should be held, exit 1 if safe to continue
#######################################
_dlw_check_worker_branch_orphan_loop() {
	local issue_number="$1"
	local repo_slug="$2"
	local worker_worktree_branch="$3"
	local worker_worktree_reused="${4:-0}"
	local todo_file="${5:-TODO.md}"
	local worker_worktree_path="${6:-}"

	[[ "$worker_worktree_reused" == "1" ]] || return 1
	[[ -n "$worker_worktree_branch" ]] || return 1

	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	[[ -x "$dedup_helper" ]] || return 1

	local orphan_loop_out=""
	if orphan_loop_out=$("$dedup_helper" check-orphan-loop "$issue_number" "$repo_slug" "$worker_worktree_branch" "$todo_file" "$worker_worktree_path" 2>/dev/null); then
		if [[ "$orphan_loop_out" == *"WORKER_BRANCH_ORPHAN_AUTO_RECOVERED"* ]]; then
			echo "[dispatch_with_dedup] Auto-recovered orphan branch for #${issue_number} in ${repo_slug}: ${orphan_loop_out}" >>"$LOGFILE"
			return 1
		fi
		echo "[dispatch_with_dedup] Dispatch held for #${issue_number} in ${repo_slug}: ${orphan_loop_out}" >>"$LOGFILE"
		return 0
	fi

	return 1
}

_dlw_min_worker_floor_active() {
	local active_workers="" min_worker_floor=""
	active_workers=$(count_active_workers 2>/dev/null || echo 0)
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	min_worker_floor="${AIDEVOPS_MIN_WORKER_CONCURRENCY:-}"
	if [[ -z "$min_worker_floor" ]] && declare -F config_get >/dev/null 2>&1; then
		min_worker_floor=$(config_get "orchestration.min_worker_concurrency" "6")
	fi
	[[ -n "$min_worker_floor" ]] || min_worker_floor=6
	if ! [[ "$min_worker_floor" =~ ^[0-9]+$ ]]; then
		min_worker_floor=6
	fi
	((min_worker_floor > 0 && active_workers < min_worker_floor)) && return 0
	return 1
}

_dlw_headless_state_dir() {
	printf '%s' "${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
	return 0
}

_dlw_canary_last_failure_reason() {
	local state_dir="" reason_file="" reason=""
	state_dir=$(_dlw_headless_state_dir)
	reason_file="${state_dir}/canary-last-fail.reason"
	reason=$(cat "$reason_file" 2>/dev/null || printf '%s' "transient")
	printf '%s' "$reason"
	return 0
}

_dlw_canary_failure_is_soft() {
	local reason="$1"
	case "$reason" in
		overload | provider_error | rate_limit | timeout | transient)
			return 0
			;;
	esac
	return 1
}

_dlw_recent_worker_evidence() {
	local ttl="" ledger_file=""
	ttl="${CANARY_SOFT_FAILURE_RECENT_SUCCESS_TTL_SECONDS:-900}"
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=900
	ledger_file="${AIDEVOPS_DISPATCH_LEDGER_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/dispatch-ledger.jsonl"
	[[ -f "$ledger_file" ]] || return 1
	python3 - "$ledger_file" "$ttl" <<'PY'
import json
import sys
from datetime import datetime, timezone

ledger_path = sys.argv[1]
ttl = int(sys.argv[2])
now = datetime.now(timezone.utc).timestamp()
allowed = {"in-flight", "completed"}

def parse_ts(value):
    if not value:
        return 0
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0

try:
    with open(ledger_path, "r", encoding="utf-8") as handle:
        for raw in handle:
            try:
                entry = json.loads(raw)
            except Exception:
                continue
            if entry.get("status") not in allowed:
                continue
            stamp = parse_ts(entry.get("updated_at") or entry.get("dispatched_at"))
            if stamp and 0 <= now - stamp <= ttl:
                sys.exit(0)
except FileNotFoundError:
    pass
sys.exit(1)
PY
	return $?
}

_dlw_allow_soft_canary_failure() {
	local reason="$1"
	_dlw_canary_failure_is_soft "$reason" || return 1
	_dlw_recent_worker_evidence || return 1
	return 0
}

_dlw_claim_lock_after_canary() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local _ds_t0

	# t3549: acquire the cross-runner GitHub claim only after the canary proves
	# this runtime can start. Otherwise canary timeout storms publish persistent
	# DISPATCH_CLAIM audit noise even though no worker process will exist.
	_ds_t0=$(_ds_now_ns)
	if _dedup_layer7_claim_lock "$issue_number" "$repo_slug" "$self_login"; then
		_ds_record "$issue_number" "$repo_slug" "claim_lock" "$_ds_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "claim_lock" "$_ds_t0"
	return 0
}

_dlw_canary_preflight() {
	local issue_number="$1"
	local repo_slug="$2"
	local worker_log="$3"
	local dispatch_model_tier="$4"
	local selected_model="$5"

	local -a _canary_cmd=("$HEADLESS_RUNTIME_HELPER" canary --role worker --tier "$dispatch_model_tier")
	if [[ -n "$selected_model" ]]; then
		_canary_cmd+=(--model "$selected_model")
	fi
	local -a _canary_env=()
	if _dlw_min_worker_floor_active; then
		_canary_env+=(AIDEVOPS_MIN_WORKER_FLOOR_BYPASS_ACTIVE=1)
		echo "[dispatch_with_dedup] #${issue_number} in ${repo_slug}: minimum worker floor active — canary still checks runtime/model health only" >>"$LOGFILE"
	fi

	if env "${_canary_env[@]}" "${_canary_cmd[@]}" >>"$worker_log" 2>&1; then
		return 0
	fi

	local canary_reason
	canary_reason=$(_dlw_canary_last_failure_reason)
	if _dlw_allow_soft_canary_failure "$canary_reason"; then
		echo "[dispatch_with_dedup] #${issue_number} in ${repo_slug}: soft worker canary failure reason=${canary_reason} bypassed because recent worker evidence exists (bounded t3449)" >>"$LOGFILE"
		return 0
	fi

	pulse_stats_increment "worker_canary_preflight_failed_count" 2>/dev/null || true
	echo "[dispatch_with_dedup] Skipping #${issue_number} in ${repo_slug} — worker canary preflight failed before worktree pre-creation; will retry next cycle" >>"$LOGFILE"
	return 1
}

_dlw_opencode_storage_preflight() {
	local issue_number="$1"
	local repo_slug="$2"
	local state_dir="${HOME}/.local/share/opencode"
	local db_path="${state_dir}/opencode.db"
	local tmp_parent="${TMPDIR:-/tmp}"
	local probe_dir=""

	[[ "${AIDEVOPS_OPENCODE_STORAGE_PREFLIGHT:-1}" != "0" ]] || return 0
	[[ -d "$state_dir" ]] || return 0
	[[ -w "$state_dir" ]] || {
		echo "[dispatch_with_dedup] Skipping #${issue_number} in ${repo_slug} — OpenCode state dir is not writable: ${state_dir}" >>"$LOGFILE"
		return 1
	}
	if [[ -e "$db_path" && ! -w "$db_path" ]]; then
		echo "[dispatch_with_dedup] Skipping #${issue_number} in ${repo_slug} — OpenCode session DB is not writable" >>"$LOGFILE"
		return 1
	fi
	probe_dir=$(mktemp -d "${tmp_parent%/}/aidevops-opencode-snapshot-preflight.XXXXXX" 2>/dev/null) || {
		echo "[dispatch_with_dedup] Skipping #${issue_number} in ${repo_slug} — unable to create OpenCode snapshot temp dir under ${tmp_parent}" >>"$LOGFILE"
		return 1
	}
	if ! git -C "$probe_dir" init -q >/dev/null 2>&1; then
		rm -rf "$probe_dir" 2>/dev/null || true
		echo "[dispatch_with_dedup] Skipping #${issue_number} in ${repo_slug} — git cannot initialise temp snapshot probe" >>"$LOGFILE"
		return 1
	fi
	rm -rf "$probe_dir" 2>/dev/null || true
	return 0
}

_dlw_load_preflight() {
	local issue_number="$1"
	local repo_slug="$2"
	local max_load_per_cpu="${AIDEVOPS_DISPATCH_MAX_LOAD_PER_CPU:-3.0}"
	local current_ratio=""

	[[ "${AIDEVOPS_DISPATCH_LOAD_PREFLIGHT:-1}" != "0" ]] || return 0
	current_ratio=$(python3 - <<'PY' 2>/dev/null || true
import os
try:
    load = os.getloadavg()[0]
    cpus = os.cpu_count() or 1
    print(f"{load / cpus:.3f}")
except Exception:
    print("")
PY
)
	[[ -n "$current_ratio" ]] || return 0
	if ! python3 - "$current_ratio" "$max_load_per_cpu" >/dev/null 2>&1 <<'PY'
import sys
current = float(sys.argv[1])
maximum = float(sys.argv[2])
sys.exit(0 if current <= maximum else 1)
PY
	then
		echo "[dispatch_with_dedup] Skipping #${issue_number} in ${repo_slug} — local load_per_cpu=${current_ratio} exceeds dispatch threshold ${max_load_per_cpu}" >>"$LOGFILE"
		return 1
	fi
	return 0
}

_dlw_blocked_by_hard_stop() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_meta_json="$3"
	local repo_path="${4:-}"
	_DLW_HARD_STOP_REASON=""

	if [[ "$(type -t is_blocked_by_unresolved 2>/dev/null)" != "function" ]]; then
		_DLW_HARD_STOP_REASON="dependency-verifier-unavailable"
		echo "[dispatch_with_dedup] Hard-stop before worker bootstrap for #${issue_number} in ${repo_slug}: dependency verifier unavailable" >>"$LOGFILE"
		return 0
	fi

	local issue_body=""
	issue_body=$(printf '%s' "$issue_meta_json" | jq -r '.body // ""' 2>/dev/null) || issue_body=""
	if PULSE_DEP_GRAPH_REPO_PATH="$repo_path" is_blocked_by_unresolved "$issue_body" "$repo_slug" "$issue_number"; then
		_DLW_HARD_STOP_REASON="dependency-unresolved"
		echo "[dispatch_with_dedup] Hard-stop before worker bootstrap for #${issue_number} in ${repo_slug}: unresolved blocked-by dependency (GH#23932)" >>"$LOGFILE"
		return 0
	fi

	_DLW_HARD_STOP_REASON="clear"
	return 1
}

_dlw_record_efficiency_guardrail() {
	local name="$1"
	case "$name" in
	guardrails.stale_positive_decisions | guardrails.dispatch_dependency_violations) ;;
	*) return 1 ;;
	esac
	if declare -F gh_record_efficiency_evidence >/dev/null 2>&1; then
		gh_record_efficiency_evidence "$name" 1 2>/dev/null || true
	fi
	return 0
}

_dlw_final_dependency_attestation() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_meta_json="$3"
	local repo_path="$4"
	if _dlw_blocked_by_hard_stop "$issue_number" "$repo_slug" "$issue_meta_json" "$repo_path"; then
		if [[ "${_DLW_HARD_STOP_REASON:-}" == "dependency-unresolved" ]]; then
			# The prebootstrap dependency decision was positive, but the live
			# action-boundary recheck now blocks. Record that stale positive while
			# still preventing the worker process from starting.
			_dlw_record_efficiency_guardrail guardrails.stale_positive_decisions
		fi
		return 1
	fi
	return 0
}

_dlw_require_dependency_attestation() {
	local attested="$1"
	local issue_number="$2"
	local repo_slug="$3"
	if [[ "$attested" == "1" ]]; then
		return 0
	fi
	_dlw_record_efficiency_guardrail guardrails.dispatch_dependency_violations
	echo "[dispatch_with_dedup] Worker spawn blocked for #${issue_number} in ${repo_slug}: final dependency attestation missing" >>"$LOGFILE"
	return 1
}

_dlw_hold_repeated_recovery_failures() {
	local issue_number="$1"
	local repo_slug="$2"
	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	local recovery_loop_out=""

	[[ -x "$dedup_helper" ]] || return 1
	if recovery_loop_out=$("$dedup_helper" check-recovery-loop "$issue_number" "$repo_slug" 2>/dev/null); then
		echo "[dispatch_with_dedup] Dispatch held for #${issue_number} in ${repo_slug}: ${recovery_loop_out}" >>"$LOGFILE"
		return 0
	fi
	return 1
}

_dlw_prebootstrap_gates() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_meta_json="$3"
	local repo_path="$4"

	if _dlw_blocked_by_hard_stop "$issue_number" "$repo_slug" "$issue_meta_json" "$repo_path"; then
		return 1
	fi
	if ! _dlw_opencode_storage_preflight "$issue_number" "$repo_slug"; then
		return 1
	fi
	if ! _dlw_load_preflight "$issue_number" "$repo_slug"; then
		return 1
	fi
	if _dlw_hold_repeated_recovery_failures "$issue_number" "$repo_slug"; then
		return 1
	fi
	return 0
}

_dlw_issue_still_open_before_claim() {
	local issue_number="$1"
	local repo_slug="$2"
	local refreshed_state=""

	# GH#24437: the canonical metadata bundle is fetched before canary/model
	# preflight and may be stale by the time the dispatcher is about to publish a
	# persistent DISPATCH_CLAIM. Refresh just the issue state immediately before
	# cross-runner claim/label/worktree mutation so auto-resolved meta-issues do
	# not consume worker capacity after they close.
	refreshed_state=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json state --jq '.state // ""' | tr '[:lower:]' '[:upper:]') || refreshed_state=""
	if [[ -z "$refreshed_state" ]]; then
		echo "[dispatch_with_dedup] Warning: unable to refresh issue state for #${issue_number} in ${repo_slug} before claim; proceeding with prior dispatch gates" >>"$LOGFILE"
		return 0
	fi
	if [[ "$refreshed_state" != "OPEN" ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: refreshed issue state before claim is ${refreshed_state} (GH#24437)" >>"$LOGFILE"
		return 1
	fi

	return 0
}

_dlw_preclaim_state_refresh_or_skip() {
	local issue_number="$1"
	local repo_slug="$2"
	local _ds_t0

	_ds_t0=$(_ds_now_ns)
	if ! _dlw_issue_still_open_before_claim "$issue_number" "$repo_slug"; then
		_ds_record "$issue_number" "$repo_slug" "preclaim_state_refresh" "$_ds_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "preclaim_state_refresh" "$_ds_t0"

	return 0
}

#######################################
# Record why dispatch stopped before the canonical worker runtime started.
# Canonical runtime metrics must not include attempts that never crossed the
# runtime boundary, so this evidence remains in the issue-correlated dispatch
# stage stream and pulse log.
# Args: issue number, repo slug, low-cardinality reason, return code
#######################################
_dlw_pre_runtime_failure() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="$3"
	local return_code="${4:-2}"
	_DLW_LAST_PRE_RUNTIME_FAILURE="$reason"
	local failure_started_ns=""
	failure_started_ns=$(_ds_now_ns)
	_ds_record "$issue_number" "$repo_slug" "pre_runtime_failure:${reason}" "$failure_started_ns"
	echo "[dispatch_with_dedup] PRE_RUNTIME_FAILURE issue=${issue_number} repo=${repo_slug} reason=${reason}" >>"$LOGFILE"
	return "$return_code"
}

_dlw_final_worker_spawn_gates() {
	local issue_number="$1"
	local repo_slug="$2"
	local worker_worktree_branch="$3"
	local worker_worktree_reused="$4"
	local todo_path="$5"
	local worker_worktree_path="$6"
	local issue_meta_json="$7"
	local repo_path="$8"
	local dependency_attested=0

	if _dlw_check_worker_branch_orphan_loop "$issue_number" "$repo_slug" "$worker_worktree_branch" \
		"$worker_worktree_reused" "$todo_path" "$worker_worktree_path"; then
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "worker_branch_orphan_hold" 2 || return $?
	fi
	if ! _dlw_final_dependency_attestation "$issue_number" "$repo_slug" "$issue_meta_json" "$repo_path"; then
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "final_dependency_recheck" 2 || return $?
	fi
	dependency_attested=1
	if ! _dlw_require_dependency_attestation "$dependency_attested" "$issue_number" "$repo_slug"; then
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "dependency_attestation_missing" 2 || return $?
	fi
	return 0
}

DLW_STAGE_CANARY_PREFLIGHT="canary_preflight"

#######################################
# Thin orchestrator for worker launch. Delegates each distinct concern
# (assignment + labels, log files, model resolution, issue lock, repo pull,
# worktree pre-creation, nohup launch, post-launch bookkeeping) to dedicated
# `_dlw_*` helpers. GH#28572 keeps deterministic no-op gates under the
# cross-runner claim and publishes queued ownership only at the runtime boundary.
#
# Arguments:
#   $1  - issue_number
#   $2  - repo_slug
#   $3  - dispatch_title
#   $4  - issue_title
#   $5  - self_login
#   $6  - repo_path
#   $7  - prompt
#   $8  - session_key
#   $9  - model_override (may be empty)
#   $10 - issue_meta_json
#######################################
_dispatch_launch_worker() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_title="$3"
	local issue_title="$4"
	local self_login="$5"
	local repo_path="$6"
	local prompt="$7"
	local session_key="$8"
	local model_override="$9"
	local issue_meta_json="${10}"
	_DLW_LAST_PRE_RUNTIME_FAILURE=""

	# t3034: per-stage timing for launch sub-stages
	local _ds_t0

	local worker_log
	worker_log=$(_dlw_setup_worker_log "$repo_slug" "$issue_number")

	if ! _dlw_prebootstrap_gates "$issue_number" "$repo_slug" "$issue_meta_json" "$repo_path"; then
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "prebootstrap_gate" 2 || return $?
	fi

	_ds_t0=$(_ds_now_ns)
	_dlw_resolve_tier_and_model "$issue_meta_json" "$model_override" "$repo_path"
	_ds_record "$issue_number" "$repo_slug" "resolve_tier_model" "$_ds_t0"
	local dispatch_tier="$_DLW_DISPATCH_TIER" dispatch_model_tier="$_DLW_DISPATCH_MODEL_TIER" selected_model="$_DLW_SELECTED_MODEL"

	_ds_t0=$(_ds_now_ns)
	if ! _dlw_canary_preflight "$issue_number" "$repo_slug" "$worker_log" \
		"$dispatch_model_tier" "$selected_model"; then
		_ds_record "$issue_number" "$repo_slug" "$DLW_STAGE_CANARY_PREFLIGHT" "$_ds_t0"
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "$DLW_STAGE_CANARY_PREFLIGHT" 2 || return $?
	fi
	_ds_record "$issue_number" "$repo_slug" "$DLW_STAGE_CANARY_PREFLIGHT" "$_ds_t0"

	if ! _dlw_preclaim_state_refresh_or_skip "$issue_number" "$repo_slug"; then
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "preclaim_state_changed" 2 || return $?
	fi

	if ! _dlw_claim_lock_after_canary "$issue_number" "$repo_slug" "$self_login"; then
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "claim_lock_failed" 2 || return $?
	fi

	local zero_output_comment_metrics=""
	zero_output_comment_metrics=$(_dlw_comment_bloat_metrics "$issue_number" "$repo_slug")
	if _dlw_hold_repeated_zero_output "$issue_number" "$repo_slug" "$zero_output_comment_metrics"; then
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "repeated_zero_output_hold" 2 || return $?
	fi

	# t2981: capture pre-creation return code — skip dispatch on failure
	# instead of falling back to canonical repo on the default branch.
	_ds_t0=$(_ds_now_ns)
	if ! _dlw_precreate_worktree "$issue_number" "$repo_path"; then
		_ds_record "$issue_number" "$repo_slug" "precreate_worktree" "$_ds_t0"
		pulse_stats_increment "worktree_precreation_failed_count" 2>/dev/null || true
		echo "[dispatch_with_dedup] Skipping #${issue_number} — pre-creation failed; will retry next cycle" >>"$LOGFILE"
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "worktree_precreation_failed" 2 || return $?
	fi
	_ds_record "$issue_number" "$repo_slug" "precreate_worktree" "$_ds_t0"
	local worker_worktree_path="$_DLW_WORKTREE_PATH" worker_worktree_branch="$_DLW_WORKTREE_BRANCH" worker_worktree_reused="${_DLW_WORKTREE_REUSED:-0}"
	_dlw_final_worker_spawn_gates "$issue_number" "$repo_slug" "$worker_worktree_branch" "$worker_worktree_reused" \
		"${repo_path}/TODO.md" "$worker_worktree_path" "$issue_meta_json" "$repo_path" || return $?

	local worker_pid attempt_id="" attempt_started_at=""
	attempt_id=$(aidevops_generate_execution_id "attempt")
	attempt_started_at=$(_worker_attempt_start_marker)
	local launch_prompt=""
	launch_prompt=$(_dlw_prepare_prompt_for_launch "$issue_number" "$repo_slug" "$issue_title" "$prompt" "$zero_output_comment_metrics")

	_ds_t0=$(_ds_now_ns)
	_dlw_assign_and_label "$issue_number" "$repo_slug" "$self_login" "$issue_meta_json" || {
		_ds_record "$issue_number" "$repo_slug" "assign_and_label" "$_ds_t0"
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "assignment_failed" 2 || return $?
	}
	_ds_record "$issue_number" "$repo_slug" "assign_and_label" "$_ds_t0"

	# t1894/t1934: Lock issue and linked PRs during worker execution.
	_ds_t0=$(_ds_now_ns)
	lock_issue_for_worker "$issue_number" "$repo_slug"
	_ds_record "$issue_number" "$repo_slug" "lock_issue" "$_ds_t0"

	_ds_t0=$(_ds_now_ns)
	if ! worker_pid=$(_dlw_nohup_launch "$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
		"$session_key" "$worker_log" "$launch_prompt" "$repo_path" \
		"$dispatch_model_tier" "$selected_model" \
		"$worker_worktree_path" "$worker_worktree_branch" "$attempt_id" "$attempt_started_at"); then
		_ds_record "$issue_number" "$repo_slug" "worker_spawn" "$_ds_t0"
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "worker_launch_failed" 2 || return $?
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "worker_spawn" "$_ds_t0"

	_ds_t0=$(_ds_now_ns)
	_dlw_post_launch_hooks "$issue_number" "$repo_slug" "$self_login" \
		"$worker_pid" "$session_key" "$dispatch_tier" "$selected_model" "$worker_worktree_path" "$attempt_id"
	_ds_record "$issue_number" "$repo_slug" "post_launch_hooks" "$_ds_t0"

	echo "[dispatch_with_dedup] Dispatched worker PID ${worker_pid} for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
	return 0
}
