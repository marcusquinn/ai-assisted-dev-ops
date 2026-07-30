#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-fix-the-fixer-detector.sh — Periodic LLM-driven detector that
# classifies pending dispatches as "fix-the-fixer" (touches dispatch system
# itself) or normal, applying the `fix-the-fixer` label + advisory comment
# before workers spawn. (t3077 / GH#21841)
#
# Why this exists (t3077):
#   The deterministic t2819 self-hosting detector pattern-matches paths in
#   .agents/configs/self-hosting-files.conf to auto-elevate dispatch-path
#   tasks to opus. That works for tasks that explicitly name dispatch files,
#   but cannot catch:
#     - Indirect changes via shared lib edits (shared-constants.sh) that
#       cascade into the dispatch path.
#     - Briefs that imply dispatch-system risk without naming files
#       ("fix the worker exit semantics" with no Files Scope block).
#     - Combination tasks where one part is dispatch-system and one is not.
#   When a worker fixing a dispatch bug is killed BY that bug before
#   producing output, the failure is invisible and the task re-dispatches
#   indefinitely (canonical: #21707 → PR #21741, six wasted opus dispatches).
#
# What this does:
#   For each pending auto-dispatch issue without `fix-the-fixer` label:
#     1. Reads the issue body + linked task brief (if any).
#     2. Calls a thinking-tier LLM with a binary classification prompt.
#     3. On YES verdict, applies the `fix-the-fixer` label and posts an
#        advisory comment naming the rationale.
#   The dispatch path (headless-runtime-helper.sh, t3077 changes) reads
#   the label and enables verbose lifecycle, tighter watchdog, and a
#   preflight sentinel write.
#
# Design constraints:
#   - Idempotent: skips issues already carrying the label.
#   - Fail-open: any internal error returns 0 — the deterministic
#     t2819 detector remains the primary safety net.
#   - Capped scope: --limit caps issues per run (default 10).
#   - Cheap: defaults to claude-haiku-4-5 (~$0.001 per call); env override.
#
# Usage:
#   pulse-fix-the-fixer-detector.sh run [--repo OWNER/REPO] [--limit N]
#   pulse-fix-the-fixer-detector.sh run --dry-run   # classify but don't apply
#   pulse-fix-the-fixer-detector.sh check <issue-number> <slug>
#   pulse-fix-the-fixer-detector.sh help
#
# Bypass:
#   AIDEVOPS_FIX_THE_FIXER_DETECTOR_DISABLE=1   — exit 0 immediately
#   AIDEVOPS_FIX_THE_FIXER_DETECTOR_DRY_RUN=1   — classify, don't write
#
# Tunables:
#   AIDEVOPS_FIX_THE_FIXER_DETECTOR_MODEL       (default: simple)
#   AIDEVOPS_FIX_THE_FIXER_DETECTOR_LIMIT       (default: 10)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

readonly FIX_THE_FIXER_LABEL="fix-the-fixer"
readonly FIX_THE_FIXER_MARKER="<!-- aidevops:fix-the-fixer-detector -->"
# GH#23594: test override path. Production callers leave the env var unset
# and pick up the sibling helper; regression tests can point at a stub that
# deterministically returns a specific exit code.
readonly AI_RESEARCH_HELPER="${PULSE_AI_RESEARCH_HELPER_OVERRIDE:-${SCRIPT_DIR}/ai-research-helper.sh}"
readonly REPOS_JSON="${HOME}/.config/aidevops/repos.json"
readonly AUTH_COOLDOWN_FILE="${HOME}/.aidevops/cache/fix-the-fixer-detector-auth.cooldown"
readonly AUTH_COOLDOWN_SECONDS_DEFAULT=21600
readonly AUTH_ERROR_REASON="AI research credentials invalid"
# Sentinels used by the GitHub issue API. Extracted as constants so the
# literal strings appear once (codebase ratchet flags repeated literals).
readonly ISSUE_STATE_OPEN="OPEN"
# Log-level tokens (ditto — extracted to satisfy the repeated-literals gate).
readonly _LL_INFO="INFO"
readonly _LL_WARN="WARN"

_log() {
	local level="$1"
	shift
	printf '[fix-the-fixer-detector] %s: %s\n' "$level" "$*" >&2
	return 0
}

_log_info() {
	_log "$_LL_INFO" "$@"
	return 0
}

_log_warn() {
	_log "$_LL_WARN" "$@"
	return 0
}

_auth_item_logs_suppressed() {
	[[ "${AIDEVOPS_FIX_THE_FIXER_DETECTOR_SUPPRESS_AUTH_ITEM_LOGS:-0}" == "1" ]] || return 1
	return 0
}

_log_auth_skip() {
	if _auth_item_logs_suppressed; then
		return 0
	fi
	_log_warn "$@"
	return $?
}

_auth_cooldown_seconds() {
	local configured="${AIDEVOPS_FIX_THE_FIXER_DETECTOR_AUTH_COOLDOWN_SECONDS:-$AUTH_COOLDOWN_SECONDS_DEFAULT}"
	[[ "$configured" =~ ^[0-9]+$ && "$configured" -gt 0 ]] || configured="$AUTH_COOLDOWN_SECONDS_DEFAULT"
	printf '%s\n' "$configured"
	return 0
}

_hash_text() {
	local value="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$value" | sha256sum | awk '{ print $1 }'
		return 0
	fi
	printf '%s' "$value" | shasum -a 256 | awk '{ print $1 }'
	return 0
}

_file_mtime() {
	local path="$1"
	[[ -e "$path" ]] || {
		printf 'missing\n'
		return 0
	}
	local mtime
	mtime=$(_file_mtime_epoch "$path" 2>/dev/null) || {
		local rc=$?
		printf 'unknown\n'
		return "$rc"
	}
	printf '%s\n' "$mtime"
	return 0
}

_auth_config_stamp() {
	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	local env_state="unset"
	[[ -n "${ANTHROPIC_API_KEY:-}" ]] && env_state="set:$(_hash_text "$ANTHROPIC_API_KEY")"
	printf 'env=%s;creds=%s;helper=%s\n' \
		"$env_state" \
		"$(_file_mtime "$creds_file")" \
		"$(_file_mtime "$AI_RESEARCH_HELPER")"
	return 0
}

_is_auth_error() {
	local message="$1"
	local normalized
	normalized=$(printf '%s' "$message" | tr '[:upper:]' '[:lower:]')
	case "$normalized" in
		*"invalid x-api-key"*|*"invalid api key"*|*"authentication_error"*|*"unauthorized"*) return 0 ;;
		*) return 1 ;;
	esac
}

_record_auth_cooldown() {
	local reason="$1"
	local now
	now=$(date +%s 2>/dev/null || printf '0')
	mkdir -p "$(dirname "$AUTH_COOLDOWN_FILE")" 2>/dev/null || return 0
	{
		printf 'created_at=%s\n' "$now"
		printf 'cooldown_seconds=%s\n' "$(_auth_cooldown_seconds)"
		printf 'config_stamp=%s\n' "$(_auth_config_stamp)"
		printf 'reason=%s\n' "$reason"
	} >"$AUTH_COOLDOWN_FILE" 2>/dev/null || true
	return 0
}

_auth_cooldown_active() {
	[[ -f "$AUTH_COOLDOWN_FILE" ]] || return 1
	local created_at=""
	local cooldown_seconds=""
	local config_stamp=""
	local line=""
	while IFS= read -r line; do
		case "$line" in
			created_at=*) created_at="${line#created_at=}" ;;
			cooldown_seconds=*) cooldown_seconds="${line#cooldown_seconds=}" ;;
			config_stamp=*) config_stamp="${line#config_stamp=}" ;;
		esac
	done <"$AUTH_COOLDOWN_FILE"

	[[ "$created_at" =~ ^[0-9]+$ ]] || return 1
	[[ "$cooldown_seconds" =~ ^[0-9]+$ ]] || cooldown_seconds="$(_auth_cooldown_seconds)"
	if [[ "$config_stamp" != "$(_auth_config_stamp)" ]]; then
		rm -f "$AUTH_COOLDOWN_FILE" 2>/dev/null || true
		return 1
	fi

	local now
	now=$(date +%s 2>/dev/null || printf '0')
	[[ "$now" =~ ^[0-9]+$ ]] || return 1
	if [[ $((now - created_at)) -lt "$cooldown_seconds" ]]; then
		return 0
	fi
	rm -f "$AUTH_COOLDOWN_FILE" 2>/dev/null || true
	return 1
}

# ---------------------------------------------------------------------------
# Compose the binary classification prompt.
#
# Returns "YES <one-line rationale>" or "NO <one-line rationale>" — strictly
# 1 line, leading verdict token. Any other response is treated as NO
# (fail-open / fail-conservative — only annotate when the model is confident).
# ---------------------------------------------------------------------------
_compose_classification_prompt() {
	local issue_title="$1"
	local issue_body="$2"

	# Cap body length to keep token cost predictable. The first ~3KB
	# captures What/Why/How/Files Scope which is what classification needs.
	local body_truncated
	body_truncated="$(printf '%s' "$issue_body" | head -c 3000)"

	cat <<EOF
You are classifying a software development task to decide whether it modifies the worker dispatch system itself.

A "fix-the-fixer" task is one where the work touches:
  - The pulse dispatch loop (pulse-wrapper.sh, pulse-dispatch-*.sh)
  - The headless runtime that spawns workers (headless-runtime-helper.sh, headless-runtime-lib.sh)
  - The worker lifecycle (worker-lifecycle-common.sh, worker-activity-watchdog.sh)
  - The dispatch dedup / claim system (dispatch-dedup-helper.sh, shared-claim-lifecycle.sh, shared-dispatch-dedup.sh)
  - Worker exit classification or stuck-detection logic
  - Shared libraries that the above transitively depend on (shared-constants.sh) IF the change affects dispatch behaviour

A non-fix-the-fixer task may touch shell scripts, framework code, docs, tests, or product code without affecting the dispatch path itself.

The risk of mis-classifying a real fix-the-fixer task as non-fix-the-fixer: the worker may be killed by the very bug it is fixing, with no visible failure mode. Six wasted opus dispatches in the canonical incident (PR #21741).

The risk of false positives: extra observability flags + tighter watchdog timeouts on a normal task. Cheap.

Be CONSERVATIVE — output YES only when you have specific evidence (file paths or behaviour described in the body that names the dispatch path).

Issue title:
${issue_title}

Issue body (truncated to 3KB):
${body_truncated}

Respond with EXACTLY one line. Format:
  YES <one-line rationale citing specific evidence>
  NO <one-line rationale>

No markdown, no quotes, no preamble. The rationale is a single sentence.
EOF
	return 0
}

# ---------------------------------------------------------------------------
# Call the LLM and parse the verdict.
#
# Output (stdout): "YES" or "NO" (verdict only)
# Output (RATIONALE global): the rationale text from the verdict line.
# Returns 0 on success, 1 on LLM failure (caller treats as NO).
# ---------------------------------------------------------------------------
_classify_via_llm() {
	local issue_title="$1"
	local issue_body="$2"
	local model="${AIDEVOPS_FIX_THE_FIXER_DETECTOR_MODEL:-simple}"

	local prompt
	prompt=$(_compose_classification_prompt "$issue_title" "$issue_body")

	if _auth_cooldown_active; then
		RATIONALE="auth_error: ${AUTH_ERROR_REASON}; cooldown active"
		_log_auth_skip "fix-the-fixer detector skipped: ${AUTH_ERROR_REASON}"
		printf 'SKIP_AUTH\n'
		return 0
	fi

	if [[ ! -x "$AI_RESEARCH_HELPER" ]]; then
		_log_warn "ai-research-helper.sh not executable — cannot classify"
		return 1
	fi

	# Capture stderr so we can attribute failures (missing API key,
	# rate-limit, network, etc.) in the run-summary instead of swallowing
	# them and reporting "processed N" as if classification had happened.
	# t3223: detector silent failure — LLM outage masqueraded as 100%
	# verdict=NO output for ~6h before being noticed.
	local raw=""
	local err_log
	err_log=$(mktemp -t fix-the-fixer-llm-err.XXXXXX 2>/dev/null) || err_log=""
	# Note: SKIP paths return 0 (not 1) so set -e doesn't abort cmd_check
	# before it can propagate the SKIP verdict to the caller. SKIP is a
	# valid output of this function — "I cannot classify" is itself a
	# classification result, just a different one from YES/NO.
	if [[ -n "$err_log" ]]; then
		raw=$("$AI_RESEARCH_HELPER" --model "$model" --prompt "$prompt" --max-tokens 200 2>"$err_log") || {
			local helper_rc=$?
			local err_snippet=""
			[[ -s "$err_log" ]] && err_snippet=$(head -c 200 "$err_log" | tr '\n' ' ')
			rm -f "$err_log"
			# GH#23594: rc=2 is ai-research-helper's documented exit code for
			# "no API key resolved locally" — treat it as an auth class signal
			# regardless of the error message, so the cooldown trips even when
			# the prose message doesn't match _is_auth_error()'s API-response
			# patterns (which are tuned for invalid x-api-key / 401 responses).
			if [[ "$helper_rc" -eq 2 ]] || _is_auth_error "$err_snippet"; then
				local cooldown_reason="$err_snippet"
				if [[ "$helper_rc" -eq 2 && -z "$cooldown_reason" ]]; then
					cooldown_reason="ai-research-helper rc=2: no Anthropic credentials resolvable"
				fi
				_record_auth_cooldown "$cooldown_reason"
				RATIONALE="auth_error: ${AUTH_ERROR_REASON}"
				_log_auth_skip "fix-the-fixer detector skipped: ${AUTH_ERROR_REASON}"
				printf 'SKIP_AUTH\n'
				return 0
			fi
			RATIONALE="LLM call failed (model=${model}, rc=${helper_rc}): ${err_snippet:-no stderr}"
			_log_warn "${RATIONALE}"
			printf 'SKIP\n'
			return 0
		}
		rm -f "$err_log"
	else
		# mktemp unavailable — fall back to no stderr capture.
		raw=$("$AI_RESEARCH_HELPER" --model "$model" --prompt "$prompt" --max-tokens 200 2>/dev/null) || {
			RATIONALE="LLM call failed (model=${model}) — stderr capture unavailable"
			_log_warn "${RATIONALE}"
			printf 'SKIP\n'
			return 0
		}
	fi

	# First non-empty line is the verdict.
	local first_line
	first_line=$(printf '%s\n' "$raw" | awk 'NF { print; exit }')
	if [[ -z "$first_line" ]]; then
		RATIONALE="empty LLM output (model=${model}) — cannot classify"
		_log_warn "${RATIONALE}"
		printf 'SKIP\n'
		return 0
	fi

	# Parse verdict + rationale. Be lenient on whitespace and case.
	local verdict_token
	verdict_token=$(printf '%s' "$first_line" | awk '{ print toupper($1) }')
	RATIONALE=$(printf '%s' "$first_line" | sed -E 's/^[[:space:]]*[Yy][Ee][Ss][[:space:]:.,-]*//;s/^[[:space:]]*[Nn][Oo][[:space:]:.,-]*//')
	[[ -z "$RATIONALE" ]] && RATIONALE="(no rationale provided)"

	case "$verdict_token" in
		YES|YES.|YES,)
			printf 'YES\n'
			;;
		*)
			# Anything not-YES is treated as NO (conservative — only
			# annotate when confident).
			printf 'NO\n'
			;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Apply the label + post advisory comment. Idempotent via marker.
# ---------------------------------------------------------------------------
_apply_label_and_comment() {
	local issue_num="$1"
	local slug="$2"
	local rationale="$3"

	if [[ "${AIDEVOPS_FIX_THE_FIXER_DETECTOR_DRY_RUN:-0}" == "1" ]]; then
		_log_info "[dry-run] would apply ${FIX_THE_FIXER_LABEL} on ${slug}#${issue_num}: ${rationale}"
		return 0
	fi

	# Apply label (best-effort; ignore if already present).
	gh issue edit "$issue_num" --repo "$slug" \
		--add-label "$FIX_THE_FIXER_LABEL" >/dev/null 2>&1 || {
		_log_warn "failed to apply ${FIX_THE_FIXER_LABEL} on ${slug}#${issue_num}"
		return 0
	}

	# Idempotency check — skip comment if marker already present.
	local existing=""
	existing=$(gh api "repos/${slug}/issues/${issue_num}/comments" \
		--jq "[.[] | select(.body | contains(\"${FIX_THE_FIXER_MARKER}\"))] | length" \
		2>/dev/null) || existing=""
	if [[ "$existing" =~ ^[1-9][0-9]*$ ]]; then
		_log_info "advisory already present on ${slug}#${issue_num}; label re-applied"
		return 0
	fi

	# Post advisory comment via signed wrapper.
	local comment_body="${FIX_THE_FIXER_MARKER}
## Fix-the-Fixer Classification Applied (t3077)

This issue has been classified as a **fix-the-fixer** task — the work touches the worker dispatch system itself. Workers dispatched on this issue will run with extra observability:

- \`AIDEVOPS_VERBOSE_LIFECYCLE=1\` — emits 5+ lifecycle checkpoints visible in pulse.log.
- \`WORKER_STALL_TIMEOUT=180\` — tighter watchdog (vs 300s default) so silent failure is caught faster.
- \`AIDEVOPS_WORKER_PREFLIGHT_SENTINEL=1\` — worker writes a preflight sentinel before opencode launches; aborts dispatch with clear error if write fails (catches sandbox/FD issues before model invocation).

**Rationale:** ${rationale}

If this classification is wrong, remove the \`${FIX_THE_FIXER_LABEL}\` label and the next worker will dispatch with default settings.

_Automated by \`pulse-fix-the-fixer-detector.sh\` (t3077). Idempotent via the \`${FIX_THE_FIXER_MARKER}\` marker; re-runs on a labelled issue are no-ops._"

	# Use the wrapper if available so the signature is auto-injected.
	if command -v gh_issue_comment >/dev/null 2>&1; then
		gh_issue_comment "$issue_num" --repo "$slug" --body "$comment_body" \
			>/dev/null 2>&1 || _log_warn "advisory comment post failed on ${slug}#${issue_num}"
	else
		# shellcheck source=/dev/null
		source "${SCRIPT_DIR}/shared-gh-wrappers.sh" 2>/dev/null || true
		if command -v gh_issue_comment >/dev/null 2>&1; then
			gh_issue_comment "$issue_num" --repo "$slug" --body "$comment_body" \
				>/dev/null 2>&1 || _log_warn "advisory comment post failed on ${slug}#${issue_num}"
		else
			_log_warn "shared-gh-wrappers.sh not found; advisory comment skipped (label still applied)"
		fi
	fi

	_log_info "applied ${FIX_THE_FIXER_LABEL} + advisory on ${slug}#${issue_num}"
	return 0
}

# ---------------------------------------------------------------------------
# Check a single issue. Returns 0 always (non-blocking).
# ---------------------------------------------------------------------------
cmd_check() {
	local issue_num="$1"
	local slug="$2"

	[[ "$issue_num" =~ ^[0-9]+$ ]] || {
		_log_warn "invalid issue number: ${issue_num}"
		return 0
	}
	[[ -n "$slug" ]] || {
		_log_warn "empty slug"
		return 0
	}

	local issue_json
	issue_json=$(gh issue view "$issue_num" --repo "$slug" \
		--json title,body,labels,state 2>/dev/null) || {
		_log_warn "gh issue view failed for ${slug}#${issue_num}"
		return 0
	}

	# Skip closed issues.
	local state
	state=$(printf '%s' "$issue_json" | jq -r --arg D "$ISSUE_STATE_OPEN" '.state // $D' 2>/dev/null) || state="$ISSUE_STATE_OPEN"
	[[ "$state" != "$ISSUE_STATE_OPEN" ]] && return 0

	# Skip if already labeled (idempotent).
	local has_label
	has_label=$(printf '%s' "$issue_json" | \
		jq -r --arg L "$FIX_THE_FIXER_LABEL" \
		'[.labels[].name] | any(. == $L)' 2>/dev/null) || has_label="false"
	if [[ "$has_label" == "true" ]]; then
		_log_info "${slug}#${issue_num} already labeled — skipping"
		return 0
	fi

	# Must carry auto-dispatch (otherwise dispatch path won't fire anyway).
	local has_auto
	has_auto=$(printf '%s' "$issue_json" | \
		jq -r '[.labels[].name] | any(. == "auto-dispatch")' 2>/dev/null) || has_auto="false"
	if [[ "$has_auto" != "true" ]]; then
		return 0
	fi

	local title="" body=""
	title=$(printf '%s' "$issue_json" | jq -r '.title // ""' 2>/dev/null) || title=""
	body=$(printf '%s' "$issue_json" | jq -r '.body // ""' 2>/dev/null) || body=""
	if [[ -z "$body" ]]; then
		_log_info "${slug}#${issue_num} has empty body — skipping"
		return 0
	fi

	# Classify.
	# Return semantics (t3223 — detector silent failure fix):
	#   exit 0 + verdict=YES  → classified, label applied
	#   exit 0 + verdict=NO   → classified, no action
	#   exit 2 + verdict=SKIP → LLM unavailable, NOT classified — caller
	#                            must surface this in run summary
	#   exit 0 (other paths)  → skipped pre-classification (closed,
	#                            already labeled, no body, no auto-dispatch)
	RATIONALE=""
	local verdict
	verdict=$(_classify_via_llm "$title" "$body")
	if [[ "$verdict" == "SKIP_AUTH" ]]; then
		[[ -n "$RATIONALE" ]] || RATIONALE="auth_error: ${AUTH_ERROR_REASON}"
		_log_auth_skip "${slug}#${issue_num} classification skipped — ${RATIONALE}"
		return 3
	fi
	if [[ "$verdict" == "SKIP" ]]; then
		_log_warn "${slug}#${issue_num} classification skipped — ${RATIONALE}"
		return 2
	fi
	if [[ "$verdict" != "YES" ]]; then
		_log_info "${slug}#${issue_num} verdict=NO ${RATIONALE}"
		return 0
	fi

	_log_info "${slug}#${issue_num} verdict=YES ${RATIONALE}"
	_apply_label_and_comment "$issue_num" "$slug" "$RATIONALE"
	return 0
}

# ---------------------------------------------------------------------------
# Iterate pulse-enabled repos, fetch unlabeled auto-dispatch issues, classify.
# ---------------------------------------------------------------------------
cmd_run() {
	local repo_filter=""
	local limit="${AIDEVOPS_FIX_THE_FIXER_DETECTOR_LIMIT:-10}"
	local dry_run="${AIDEVOPS_FIX_THE_FIXER_DETECTOR_DRY_RUN:-0}"

	# Iterate args as named locals (the codebase ratchet flags direct
	# positional-parameter use inside loops and function bodies).
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		local arg_value="${2:-}"
		case "$arg" in
			--repo) repo_filter="$arg_value"; shift 2 ;;
			--limit) limit="$arg_value"; shift 2 ;;
			--dry-run) dry_run=1; shift ;;
			*) shift ;;
		esac
	done

	[[ "$limit" =~ ^[0-9]+$ ]] || limit=10
	export AIDEVOPS_FIX_THE_FIXER_DETECTOR_DRY_RUN="$dry_run"

	if [[ "${AIDEVOPS_FIX_THE_FIXER_DETECTOR_DISABLE:-0}" == "1" ]]; then
		_log_info "AIDEVOPS_FIX_THE_FIXER_DETECTOR_DISABLE=1 — bypassing run"
		return 0
	fi

	# Resolve target repos.
	local -a target_repos=()
	if [[ -n "$repo_filter" ]]; then
		target_repos=("$repo_filter")
	elif [[ -f "$REPOS_JSON" ]]; then
		# Iterate pulse-enabled, non-local-only repos.
		local repos_str
		repos_str=$(jq -r '.initialized_repos[]? | select(.maintenance != false) | select(.pulse == true) | select((.local_only // false) == false) | .slug' "$REPOS_JSON" 2>/dev/null) || repos_str=""
		while IFS= read -r r; do
			[[ -n "$r" ]] && target_repos+=("$r")
		done <<<"$repos_str"
	fi

	if [[ "${#target_repos[@]}" -eq 0 ]]; then
		_log_info "no target repos resolved — exiting"
		return 0
	fi

	# Track classified vs skipped separately so a 100% LLM outage doesn't
	# masquerade as "processed N issues" — the failure mode this whole
	# fix exists to surface (t3223).
	local processed=0
	local classified=0
	local skipped_llm=0
	local skipped_auth=0
	export AIDEVOPS_FIX_THE_FIXER_DETECTOR_SUPPRESS_AUTH_ITEM_LOGS=1
	local slug
	for slug in "${target_repos[@]}"; do
		[[ "$processed" -ge "$limit" ]] && break

		# Find auto-dispatch issues without fix-the-fixer label.
		# -L 5 caps per-repo; outer loop caps overall.
		local issues_json
		issues_json=$(gh issue list --repo "$slug" \
			--label "auto-dispatch" \
			--state open --limit 30 \
			--json number,labels 2>/dev/null) || continue

		local nums
		nums=$(printf '%s' "$issues_json" | \
			jq -r --arg L "$FIX_THE_FIXER_LABEL" \
			'.[] | select([.labels[].name] | any(. == $L) | not) | .number' 2>/dev/null) || nums=""

		while IFS= read -r issue_num; do
			[[ -z "$issue_num" ]] && continue
			[[ "$processed" -ge "$limit" ]] && break
			# `set -e` is on; capture rc explicitly so cmd_check's
			# exit 2 (LLM SKIP) doesn't kill the loop.
			local rc=0
			cmd_check "$issue_num" "$slug" || rc=$?
			case "$rc" in
				3) skipped_auth=$((skipped_auth + 1)) ;;
				2) skipped_llm=$((skipped_llm + 1)) ;;
				*) classified=$((classified + 1)) ;;
			esac
			processed=$((processed + 1))
		done <<<"$nums"
	done

	if [[ "$skipped_auth" -gt 0 ]]; then
		_log_warn "processed ${processed} issue(s) across ${#target_repos[@]} repo(s) — classified=${classified}, skipped:auth-error=${skipped_auth}, skipped:LLM-failure=${skipped_llm} (detector observability degraded; ${AUTH_ERROR_REASON})"
	elif [[ "$skipped_llm" -gt 0 ]]; then
		# Loud signal — the original t3223 incident was a 6h silent LLM
		# outage. WARN level so it surfaces in the dashboards/log filters.
		_log_warn "processed ${processed} issue(s) across ${#target_repos[@]} repo(s) — classified=${classified}, skipped:auth-error=0, skipped:LLM-failure=${skipped_llm} (detector observability degraded; check ai-research-helper.sh / API credentials)"
	else
		_log_info "processed ${processed} issue(s) across ${#target_repos[@]} repo(s) — classified=${classified}, skipped:auth-error=0, skipped:LLM-failure=0"
	fi
	return 0
}

cmd_help() {
	cat <<'EOF'
pulse-fix-the-fixer-detector.sh — LLM-driven detector for dispatch-system tasks (t3077).

Usage:
  pulse-fix-the-fixer-detector.sh run [--repo OWNER/REPO] [--limit N] [--dry-run]
  pulse-fix-the-fixer-detector.sh check <issue-number> <slug>
  pulse-fix-the-fixer-detector.sh help

Commands:
  run      Iterate pulse-enabled repos (or single --repo), classify pending
           auto-dispatch issues, apply fix-the-fixer label + advisory on YES.
  check    Classify a single issue.
  help     Print this message.

Flags:
  --repo OWNER/REPO     Limit run to one repo (default: all pulse-enabled).
  --limit N             Cap issues per run (default: 10).
  --dry-run             Classify but do not apply labels or comments.

Exit codes:
  0   Always (non-blocking by design).

Bypass:
  AIDEVOPS_FIX_THE_FIXER_DETECTOR_DISABLE=1   — exit 0 immediately
  AIDEVOPS_FIX_THE_FIXER_DETECTOR_DRY_RUN=1   — same as --dry-run

Tunables:
  AIDEVOPS_FIX_THE_FIXER_DETECTOR_MODEL       (default: simple)
  AIDEVOPS_FIX_THE_FIXER_DETECTOR_LIMIT       (default: 10)
EOF
	return 0
}

main() {
	local subcmd="${1:-help}"
	shift || true

	case "$subcmd" in
		run)   cmd_run "$@" ;;
		check)
			if [[ $# -lt 2 ]]; then
				_log "ERROR" "check requires <issue-number> <slug>"
				return 2
			fi
			# Assign positionals to named locals (codebase ratchet flags
			# direct $1/$2 use inside function bodies).
			local _check_issue="$1"
			local _check_slug="$2"
			cmd_check "$_check_issue" "$_check_slug"
			;;
		help|--help|-h) cmd_help ;;
		*)
			_log "ERROR" "unknown subcommand: ${subcmd}"
			cmd_help >&2
			return 2
			;;
	esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
	main "$@"
fi
