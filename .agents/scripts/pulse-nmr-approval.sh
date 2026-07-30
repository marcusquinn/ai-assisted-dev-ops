#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-nmr-approval.sh — Needs-maintainer-review (NMR) cache, approval requirement checks, and maintainer auto-approve.
#
# Extracted from pulse-wrapper.sh in Phase 2 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _ever_nmr_cache_key
#   - _ever_nmr_cache_load
#   - _ever_nmr_cache_with_lock
#   - _ever_nmr_cache_get
#   - _ever_nmr_cache_set_locked
#   - _ever_nmr_cache_set
#   - issue_was_ever_nmr
#   - issue_has_required_approval
#   - _nmr_applied_by_maintainer
#   - _nmr_application_is_security_sensitive
#   - notify_ever_nmr_without_approval
#   - _find_qualifying_pr_for_stale_recovery
#   - _notify_stale_recovery_resolved_by_pr
#   - _nmr_current_actor_can_post_maintainer_approval
#   - auto_approve_maintainer_issues
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_NMR_APPROVAL_LOADED:-}" ]] && return 0
_PULSE_NMR_APPROVAL_LOADED=1
NMR_SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" || return 1

if ! declare -F _gh_collaborator_permission_lookup >/dev/null 2>&1; then
	_PULSE_NMR_APPROVAL_DIR="${BASH_SOURCE[0]%/*}"
	if [[ -f "${_PULSE_NMR_APPROVAL_DIR}/github-app-auth-helper.sh" ]]; then
		# shellcheck source=./github-app-auth-helper.sh
		source "${_PULSE_NMR_APPROVAL_DIR}/github-app-auth-helper.sh"
	fi
	if [[ -f "${_PULSE_NMR_APPROVAL_DIR}/shared-gh-wrappers-rest-fallback.sh" ]]; then
		# shellcheck source=./shared-gh-wrappers-rest-fallback.sh
		source "${_PULSE_NMR_APPROVAL_DIR}/shared-gh-wrappers-rest-fallback.sh"
	fi
	if [[ -f "${_PULSE_NMR_APPROVAL_DIR}/shared-gh-collaborator-permission.sh" ]]; then
		# shellcheck source=./shared-gh-collaborator-permission.sh
		source "${_PULSE_NMR_APPROVAL_DIR}/shared-gh-collaborator-permission.sh"
	fi
	unset _PULSE_NMR_APPROVAL_DIR
fi

NMR_REVALIDATION_STATE_FILE="${AIDEVOPS_NMR_REVALIDATION_STATE_FILE:-${HOME}/.aidevops/cache/nmr-revalidation-state.json}"
NMR_TEMPORARY_REVALIDATE_SECONDS="${AIDEVOPS_NMR_TEMPORARY_REVALIDATE_SECONDS:-3600}"
NMR_REASON_FILTER="${NMR_SCRIPT_DIR}/pulse-nmr-reason.jq"
NMR_TRUSTED_RESOLUTION_FILTER="${NMR_SCRIPT_DIR}/pulse-nmr-trusted-resolution.jq"
NMR_STATE_RECORD_FILTER="${NMR_SCRIPT_DIR}/pulse-nmr-state-record.jq"
NMR_LATEST_EVENT_FILTER="${NMR_SCRIPT_DIR}/pulse-nmr-latest-event.jq"
NMR_API_COMMENTS_SUFFIX="/comments"
NMR_REASON_AUTHORITY="authority"
NMR_CLASS_GENUINE_AUTHORITY="genuine-authority"
NMR_CLASS_TEMPORARY="temporary"
NMR_SOURCE_DEFAULT="default"
NMR_STATUS_HUMAN_AUTHORITY="human-authority-required"

_nmr_metadata_json() {
	local code="$1"
	local reason_class="$2"
	local source="$3"
	local requires_crypto="$4"
	jq -cn --arg code "$code" --arg class "$reason_class" --arg source "$source" \
		--argjson requires_crypto "$requires_crypto" \
		'{code:$code,class:$class,source:$source,revalidate_after_seconds:null,requires_crypto:$requires_crypto}'
	return 0
}

_nmr_issue_api_path() {
	local issue_num="$1"
	local slug="$2"
	local suffix="${3:-}"
	printf 'repos/%s/issues/%s%s\n' "$slug" "$issue_num" "$suffix"
	return 0
}

#######################################
# Cached ever-NMR provenance helpers (GH#17458)
#
# Positive results are immutable and can be cached indefinitely.
# Negative results are cached for a short TTL to avoid a timeline API call
# on every dispatch candidate while still noticing new NMR labels promptly.
#######################################
_ever_nmr_cache_key() {
	local issue_num="$1"
	local slug="$2"
	printf '%s\n' "${slug}#${issue_num}"
	return 0
}

_ever_nmr_cache_load() {
	if [[ ! -f "$EVER_NMR_CACHE_FILE" ]]; then
		printf '{}\n'
		return 0
	fi

	local content
	content=$(cat "$EVER_NMR_CACHE_FILE" 2>/dev/null) || content="{}"
	if ! printf '%s' "$content" | jq empty >/dev/null 2>&1; then
		content="{}"
	fi

	printf '%s\n' "$content"
	return 0
}

_ever_nmr_cache_with_lock() {
	local lock_dir="${EVER_NMR_CACHE_FILE}.lockdir"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			echo "[pulse-wrapper] _ever_nmr_cache_with_lock: lock acquisition timed out" >>"$LOGFILE"
			return 1
		fi
		# Stale lock detection: read the owner PID stored in the lock directory.
		# If that process is no longer running, the lock is orphaned — clear it.
		local _nmr_owner_pid
		_nmr_owner_pid=$(cat "${lock_dir}/owner.pid" 2>/dev/null || true)
		if [[ -n "$_nmr_owner_pid" ]] && ! kill -0 "$_nmr_owner_pid" 2>/dev/null; then
			echo "[pulse-wrapper] _ever_nmr_cache_with_lock: clearing stale lock (owner PID ${_nmr_owner_pid} gone)" >>"$LOGFILE"
			rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
			rmdir "$lock_dir" 2>/dev/null || true
			continue
		fi
		sleep 0.1
	done

	# Record owner PID inside lock directory so retrying callers can detect staleness.
	printf '%s\n' "$$" >"${lock_dir}/owner.pid" 2>/dev/null || true
	local rc=0
	"$@" || rc=$?
	rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return "$rc"
}

_ever_nmr_cache_get() {
	local issue_num="$1"
	local slug="$2"
	local key now_epoch cache_json cache_value checked_at age

	key=$(_ever_nmr_cache_key "$issue_num" "$slug")
	now_epoch=$(date +%s)
	cache_json=$(_ever_nmr_cache_load)
	cache_value=$(printf '%s' "$cache_json" | jq -r --arg key "$key" 'if .[$key] == null then "unknown" elif .[$key].ever_nmr == true then "true" elif .[$key].ever_nmr == false then "false" else "unknown" end' 2>/dev/null) || cache_value="unknown"
	checked_at=$(printf '%s' "$cache_json" | jq -r --arg key "$key" '.[$key].checked_at // 0' 2>/dev/null) || checked_at=0
	[[ "$checked_at" =~ ^[0-9]+$ ]] || checked_at=0

	if [[ "$cache_value" == "true" ]]; then
		printf 'true\n'
		return 0
	fi

	if [[ "$cache_value" == "false" ]]; then
		age=$((now_epoch - checked_at))
		if [[ "$age" -lt "$EVER_NMR_NEGATIVE_CACHE_TTL_SECS" ]]; then
			printf 'false\n'
			return 0
		fi
	fi

	printf 'unknown\n'
	return 0
}

_ever_nmr_cache_set_locked() {
	local issue_num="$1"
	local slug="$2"
	local cache_value="$3"
	local state_dir cache_json key now_epoch tmp_file

	[[ "$cache_value" == "true" || "$cache_value" == "false" ]] || return 1

	state_dir=$(dirname "$EVER_NMR_CACHE_FILE")
	mkdir -p "$state_dir" 2>/dev/null || true
	cache_json=$(_ever_nmr_cache_load)
	key=$(_ever_nmr_cache_key "$issue_num" "$slug")
	now_epoch=$(date +%s)
	tmp_file=$(mktemp "${state_dir}/.ever-nmr-cache.XXXXXX" 2>/dev/null) || return 0

	if printf '%s' "$cache_json" | jq --arg key "$key" --argjson checked_at "$now_epoch" --argjson ever_nmr "$cache_value" '.[$key] = {ever_nmr: $ever_nmr, checked_at: $checked_at}' >"$tmp_file" 2>/dev/null; then
		mv "$tmp_file" "$EVER_NMR_CACHE_FILE" || {
			rm -f "$tmp_file"
			echo "[pulse-wrapper] _ever_nmr_cache_set_locked: failed to move cache file" >>"$LOGFILE"
		}
	else
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _ever_nmr_cache_set_locked: failed to write cache entry" >>"$LOGFILE"
	fi

	return 0
}

_ever_nmr_cache_set() {
	_ever_nmr_cache_with_lock _ever_nmr_cache_set_locked "$@" || return 0
	return 0
}

#######################################
# Check if an issue was ever labeled needs-maintainer-review (t1894).
# Uses the immutable GitHub timeline API — label removal does not erase
# the history. This is the provenance gate: once an issue is tagged NMR,
# it requires cryptographic approval forever, regardless of current labels.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - optional precomputed status: true|false|unknown
# Returns: 0 if the issue was ever NMR-labeled, 1 otherwise
#######################################
issue_was_ever_nmr() {
	local issue_num="$1"
	local slug="$2"
	local known_status="${3:-unknown}"

	[[ -n "$issue_num" && -n "$slug" ]] || return 1

	case "$known_status" in
	true)
		return 0
		;;
	false)
		return 1
		;;
	esac

	local cache_status
	cache_status=$(_ever_nmr_cache_get "$issue_num" "$slug")
	case "$cache_status" in
	true)
		return 0
		;;
	false)
		return 1
		;;
	esac

	local ever_count
	ever_count=$(gh api "repos/${slug}/issues/${issue_num}/timeline" --paginate \
		--jq '[.[] | select(.event == "labeled" and .label.name == "needs-maintainer-review")] | length' \
		2>/dev/null) || ever_count=0
	[[ "$ever_count" =~ ^[0-9]+$ ]] || ever_count=0

	if [[ "$ever_count" -gt 0 ]]; then
		_ever_nmr_cache_set "$issue_num" "$slug" "true"
		return 0
	fi

	_ever_nmr_cache_set "$issue_num" "$slug" "false"
	return 1
}

#######################################
# Check if an issue requires cryptographic approval and has it (t1894).
# Combines the "ever-NMR" provenance check with signature verification.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - optional precomputed status: true|false|unknown
# Returns: 0 if the issue is approved (or never needed approval), 1 if blocked
#######################################
issue_has_required_approval() {
	local issue_num="$1"
	local slug="$2"
	local known_status="${3:-unknown}"

	# If it was never NMR-labeled, no approval needed
	if ! issue_was_ever_nmr "$issue_num" "$slug" "$known_status"; then
		return 0
	fi

	# It was NMR-labeled at some point — check for cryptographic approval
	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"
	if [[ -f "$approval_helper" ]]; then
		local verify_result
		verify_result=$(bash "$approval_helper" verify "$issue_num" "$slug" 2>/dev/null) || verify_result=""
		if [[ "$verify_result" == "VERIFIED" ]]; then
			return 0
		fi
	fi

	# Was ever NMR, no signed approval found — blocked
	return 1
}

#######################################
# GH#18671 / t2386: Check whether an NMR label application on an issue
# corresponds to a *creation-time automation default* — a marker that
# means "the pulse applied NMR by default, not because retries failed."
# Creation defaults are safe to auto-clear so the issue can dispatch.
#
# This function used to also match circuit-breaker trip markers
# (stale-recovery-tick:escalated, cost-circuit-breaker:fired,
# circuit-breaker-escalated). That was a design bug: it caused
# auto_approve_maintainer_issues to strip NMR from breaker-tripped
# issues immediately, re-dispatch the worker, let it fail again, and
# re-trip the breaker — an infinite loop. #19756 burned ~30 worker
# sessions and fired 22 watchdog kills + 5 auto-approve cycles in one
# afternoon before the loop was diagnosed.
#
# Breaker trip detection now lives in `_nmr_application_is_circuit_breaker_trip`
# below. `_nmr_applied_by_maintainer` consults both helpers and routes
# breaker trips to "preserve NMR" while still auto-clearing
# creation defaults. See t2386 brief and AGENTS.md
# "Cryptographic issue/PR approval" for the split semantics.
#
# Creation-default signatures detected (t2686 extended set):
#   - source:review-scanner                 — GH#18538 post-merge-review-scanner.sh (comment marker)
#   - source:review-feedback                — quality-feedback-helper.sh (comment marker)
#   - quality-feedback-helper.sh            — quality-feedback-helper.sh (comment body marker)
#   - review-followup / source:review-scanner / source:review-feedback labels on issue itself
#
# Args:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#   $3 - label_at   : ISO8601 timestamp when NMR label was applied
#
# Exit codes:
#   0 - creation-default signature found (NMR is a scanner default, safe to auto-clear)
#   1 - no creation-default signature (NMR is either manual or a breaker trip)
#######################################
_nmr_application_has_automation_signature() {
	local issue_num="$1"
	local slug="$2"
	local label_at="$3"

	[[ -n "$issue_num" && -n "$slug" && -n "$label_at" ]] || return 1

	# Fetch all issue comments once. Filter in jq to any comment posted
	# within a 60-second window of the label event AND containing a
	# creation-default marker. Window math: label_at - 5s ≤
	# comment.created_at ≤ label_at + 60s (lower bound covers the API
	# latency race where the comment posts before the label API call
	# completes).
	#
	# Markers matched (t2686 extended set):
	#   - source:review-scanner     — post-merge-review-scanner.sh (GH#18538)
	#   - source:review-feedback    — quality-feedback-helper.sh scan-merged
	#   - quality-feedback-helper.sh — approval-instructions comment body
	local has_signature
	has_signature=$(gh api "repos/${slug}/issues/${issue_num}/comments" --paginate \
		--jq "[.[] | select((.created_at | fromdateiso8601) >= ((\"${label_at}\" | fromdateiso8601) - 5) and (.created_at | fromdateiso8601) <= ((\"${label_at}\" | fromdateiso8601) + 60)) | .body | select(test(\"source:review-scanner|source:review-feedback|quality-feedback-helper\\\\.sh\"))] | length" \
		2>/dev/null) || has_signature=0
	[[ "$has_signature" =~ ^[0-9]+$ ]] || has_signature=0

	if [[ "$has_signature" -gt 0 ]]; then
		return 0
	fi

	# Also accept: the issue itself carries a scanner provenance label
	# (bot-generated cleanup). These issues apply NMR at creation via the
	# scanner default, which does not necessarily emit a post-label comment
	# marker.
	#
	# GH#20758: Co-temporality guard — scanner labels persist for the life
	# of the issue, so a label-only match without timing verification
	# misclassifies later NMR events (manual holds, breaker trips) as
	# creation defaults. Only match when NMR was applied within 300s of
	# issue creation. This closes the ever-NMR trap for scanner-labelled
	# issues that subsequently trip a circuit breaker.
	#
	# Labels matched (t2686 extended set):
	#   - review-followup           — post-merge-review-scanner.sh (GH#18538)
	#   - source:review-scanner     — post-merge-review-scanner.sh
	#   - source:review-feedback    — quality-feedback-helper.sh scan-merged
	local issue_meta_json
	issue_meta_json=$(gh api "repos/${slug}/issues/${issue_num}" 2>/dev/null) || issue_meta_json=""

	local has_bot_label=0
	if [[ -n "$issue_meta_json" ]]; then
		has_bot_label=$(printf '%s' "$issue_meta_json" \
			| jq '[.labels[].name] | map(select(. == "review-followup" or . == "source:review-scanner" or . == "source:review-feedback")) | length' \
			2>/dev/null) || has_bot_label=0
	fi
	[[ "$has_bot_label" =~ ^[0-9]+$ ]] || has_bot_label=0

	if [[ "$has_bot_label" -gt 0 ]]; then
		# Co-temporality check: NMR must have been applied within 300s of
		# issue creation to classify as a creation default. Later NMR events
		# on the same issue are either manual holds or breaker trips.
		local issue_created_at
		issue_created_at=$(printf '%s' "$issue_meta_json" \
			| jq -r '.created_at // ""' 2>/dev/null) || issue_created_at=""
		if [[ -n "$issue_created_at" && -n "$label_at" ]]; then
			local nmr_creation_gap
		nmr_creation_gap=$(jq -n --arg c "$issue_created_at" --arg l "$label_at" \
			'(($l | fromdateiso8601) - ($c | fromdateiso8601)) | abs | floor') || nmr_creation_gap=999999
			[[ "$nmr_creation_gap" =~ ^[0-9]+$ ]] || nmr_creation_gap=999999
			if (( nmr_creation_gap <= 300 )); then
				return 0
			fi
		fi
		# Scanner label present but NMR applied far from creation — not a
		# creation default. Fall through to return 1.
	fi

	return 1
}

#######################################
# t2386: Check whether an NMR label application corresponds to a
# circuit-breaker trip — one of the automated safety mechanisms that
# STOPS further dispatch when a retry limit has been exceeded or a
# cost budget has been exhausted.
#
# Breaker trips MUST preserve NMR. auto_approve_maintainer_issues
# skips issues with a breaker-trip signature, leaving NMR in place
# until a human runs `sudo aidevops approve issue <N>` after reviewing
# why the breaker tripped. This is the safety mechanism whose defeat
# caused the #19756 infinite-loop incident.
#
# Breaker-trip signatures detected:
#   - <!-- stale-recovery-tick:escalated   — t2008 stale recovery (retry limit)
#   - <!-- cost-circuit-breaker:fired      — t2007 cost circuit breaker (budget)
#   - <!-- cost-circuit-breaker:no_work_loop — t2769 per-issue no_work breaker
#   - <!-- dispatch-backoff:rate_limit_nmr — t2781 per-issue rate-limit breaker
#   - <!-- dispatch-infrastructure-failure — t3050 setup/zero-session breaker
#   - <!-- dispatch-circuit-breaker:worker_recovery_loop — issue-level recovery fuse
#   - <!-- circuit-breaker-escalated       — legacy fast-fail alias
#   - <!-- circuit-breaker-meta-filed      — t3076 root-cause meta-issue marker
#
# Args:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#   $3 - label_at   : ISO8601 timestamp when NMR label was applied
#
# Exit codes:
#   0 - breaker-trip signature found (NMR must be preserved)
#   1 - no breaker-trip signature
#######################################
_nmr_application_is_circuit_breaker_trip() {
	local issue_num="$1"
	local slug="$2"
	local label_at="$3"

	[[ -n "$issue_num" && -n "$slug" && -n "$label_at" ]] || return 1

	# Same ±60s window as _nmr_application_has_automation_signature —
	# breaker helpers (dispatch-dedup-stale.sh, dispatch-dedup-cost.sh,
	# and the t2769 no_work breaker in worker-lifecycle-common.sh) post
	# the marker comment immediately after applying the NMR label,
	# so the two events are always co-temporal.
	#
	# Use --slurp with paginated comment reads. Without flattening all pages,
	# gh --paginate --jq can emit one count per page; shell numeric coercion then
	# turns "0\n1" into 0 and misses breaker markers on later pages.
	#
	# t3076: the meta-filer posts its `circuit-breaker-meta-filed` marker
	# as a sibling comment on the same trip-cycle, so it falls inside the
	# same ±60s window — no separate query needed.
	local comments_api
	printf -v comments_api 'repos/%s/issues/%s/comments' "$slug" "$issue_num"
	local comments_json
	comments_json=$(gh api "$comments_api" --paginate --slurp 2>/dev/null) || comments_json="[]"
	if [[ -z "$comments_json" || "$comments_json" == "null" ]]; then
		comments_json="[]"
	fi

	local breaker_pattern='stale-recovery-tick:escalated|cost-circuit-breaker:fired|cost-circuit-breaker:no_work_loop|dispatch-backoff:rate_limit_nmr|dispatch-infrastructure-failure|dispatch-circuit-breaker:worker_recovery_loop|circuit-breaker-escalated|circuit-breaker-meta-filed'
	local has_breaker_trip
	has_breaker_trip=$(printf '%s' "$comments_json" | jq -r \
		--arg label_at "$label_at" \
		--arg breaker_pattern "$breaker_pattern" '
		(if type == "array" and (.[0]? | type) == "array" then [.[][]]
		elif type == "array" then .
		else [] end)
		| [
			.[]
			| select(.created_at != null)
			| select((.created_at | fromdateiso8601) >= (($label_at | fromdateiso8601) - 5)
				and (.created_at | fromdateiso8601) <= (($label_at | fromdateiso8601) + 60))
			| select((.body // "") | test($breaker_pattern))
		]
		| length
	' 2>/dev/null) || has_breaker_trip=0
	[[ "$has_breaker_trip" =~ ^[0-9]+$ ]] || has_breaker_trip=0

	if [[ "$has_breaker_trip" -gt 0 ]]; then
		return 0
	fi

	return 1
}

#######################################
# Check whether the current NMR label is part of an unresolved breaker episode.
#
# Recovery-loop incidents: a recovery/cost/no-work breaker can apply NMR with a
# marker, then a later automated retry can fail and re-apply NMR without
# reposting the original marker. Looking only at the latest label event then
# misclassifies the issue as a safe maintainer-authored automation default and
# creates repeated approval comments + worker launches.
#
# This helper deliberately searches breaker markers at or before the latest NMR
# label event. Once a breaker marker exists, the NMR remains a real hold until
# cryptographic approval or a newer aidevops release allows one retry.
#
# Args:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#   $3 - label_at   : ISO8601 timestamp when NMR label was applied
#
# Exit codes:
#   0 - prior breaker marker found (preserve NMR unless release retry applies)
#   1 - no prior breaker marker found
#######################################
_nmr_application_has_breaker_history() {
	local issue_num="$1"
	local slug="$2"
	local label_at="$3"

	[[ -n "$issue_num" && -n "$slug" && -n "$label_at" ]] || return 1

	local comments_api
	printf -v comments_api 'repos/%s/issues/%s/comments' "$slug" "$issue_num"
	local comments_json
	comments_json=$(gh api "$comments_api" --paginate --slurp 2>/dev/null) || comments_json="[]"
	if [[ -z "$comments_json" || "$comments_json" == "null" ]]; then
		comments_json="[]"
	fi

	local breaker_pattern='stale-recovery-tick:escalated|cost-circuit-breaker:fired|cost-circuit-breaker:no_work_loop|dispatch-backoff:rate_limit_nmr|dispatch-infrastructure-failure|dispatch-circuit-breaker:worker_recovery_loop|circuit-breaker-escalated|circuit-breaker-meta-filed'
	local has_breaker_history
	has_breaker_history=$(printf '%s' "$comments_json" | jq -r \
		--arg label_at "$label_at" \
		--arg breaker_pattern "$breaker_pattern" '
		(if type == "array" and (.[0]? | type) == "array" then [.[][]]
		elif type == "array" then .
		else [] end)
		| [
			.[]
			| select(.created_at != null)
			| select((.created_at | fromdateiso8601) <= (($label_at | fromdateiso8601) + 60))
			| select((.body // "") | test($breaker_pattern))
		]
		| length
	' 2>/dev/null) || has_breaker_history=0
	[[ "$has_breaker_history" =~ ^[0-9]+$ ]] || has_breaker_history=0

	if [[ "$has_breaker_history" -gt 0 ]]; then
		return 0
	fi

	return 1
}

#######################################
# Check whether an NMR issue is security-sensitive.
#
# Security-labelled work must not be auto-cleared by the generic
# creation-default path. The NMR label is the human review gate for findings
# involving credentials, auth, approval/merge gates, supply chain, and similar
# security boundaries. A scanner provenance marker proves automation created
# the issue; it does not prove the recommended remediation is safe to dispatch.
#
# <!-- aidevops:trust-boundary -->
# Treat the public `security` and `security-review` labels as authoritative
# current-state holds. Once present, NMR requires cryptographic approval instead
# of maintainer auto-approval.
#
# Args:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#   $3 - issue_meta : optional precomputed issue metadata JSON
#
# Exit codes:
#   0 - security-sensitive label present (NMR must be preserved)
#   1 - no security-sensitive label found
#######################################
_nmr_application_is_security_sensitive() {
	local issue_num="$1"
	local slug="$2"
	local precomputed_meta="${3:-}"

	[[ -n "$issue_num" && -n "$slug" ]] || return 1

	local issue_meta_json="$precomputed_meta"
	if [[ -z "$issue_meta_json" ]]; then
		local issue_api_path
		printf -v issue_api_path 'repos/%s/issues/%s' "$slug" "$issue_num"
		issue_meta_json=$(gh api "$issue_api_path" 2>/dev/null) || issue_meta_json=""
	fi
	[[ -n "$issue_meta_json" ]] || return 1

	local has_security_label
	has_security_label=$(printf '%s' "$issue_meta_json" \
		| jq --arg security_label 'security' --arg security_review_label 'security-review' \
			'[(.labels // [])[].name] | map(select(. == $security_label or . == $security_review_label)) | length' \
			2>/dev/null) || has_security_label=0
	[[ "$has_security_label" =~ ^[0-9]+$ ]] || has_security_label=0

	if [[ "$has_security_label" -gt 0 ]]; then
		return 0
	fi

	return 1
}

#######################################
# Convert a dotted version string into a sortable zero-padded key.
#
# Args:
#   $1 - version string (for example 3.14.94)
# Stdout: sortable key, or empty when invalid.
#######################################
_nmr_version_sort_key() {
	local version_raw="$1"
	local version=""
	version=$(printf '%s' "$version_raw" | grep -oE '[0-9]+(\.[0-9]+){0,3}' | head -1) || version=""
	[[ -n "$version" ]] || { printf '\n'; return 0; }

	local major=0 minor=0 patch=0 build=0
	IFS=. read -r major minor patch build <<<"$version"
	major="${major:-0}"
	minor="${minor:-0}"
	patch="${patch:-0}"
	build="${build:-0}"
	printf '%06d%06d%06d%06d\n' "$major" "$minor" "$patch" "$build" 2>/dev/null || printf '\n'
	return 0
}

#######################################
# Detect the currently deployed aidevops version.
#
# Stdout: version string, or empty when unknown.
#######################################
_nmr_current_aidevops_version() {
	if [[ -n "${AIDEVOPS_CURRENT_VERSION_OVERRIDE:-}" ]]; then
		printf '%s\n' "$AIDEVOPS_CURRENT_VERSION_OVERRIDE"
		return 0
	fi

	if declare -F aidevops_find_version >/dev/null 2>&1; then
		aidevops_find_version 2>/dev/null || true
		return 0
	fi

	local version_file="${AGENTS_DIR:-$HOME/.aidevops/agents}/VERSION"
	if [[ -f "$version_file" ]]; then
		tr -d '[:space:]' <"$version_file" 2>/dev/null || true
		return 0
	fi

	printf '\n'
	return 0
}

#######################################
# Find the retry-eligible breaker marker for an NMR episode.
#
# Args:
#   $1 - comments_json  : GitHub issue comments JSON, possibly slurped pages
#   $2 - label_at       : latest NMR label timestamp
#   $3 - retry_pattern  : regex for retry-eligible breaker markers
# Stdout: compact JSON object `{at, body}` or empty.
# Returns: 0 when found, 1 otherwise.
#######################################
_nmr_retry_breaker_event_json() {
	local comments_json="$1"
	local label_at="$2"
	local retry_pattern="$3"
	local array_type='array'

	[[ -n "$comments_json" && -n "$label_at" && -n "$retry_pattern" ]] || return 1

	local breaker_event_json=""
	breaker_event_json=$(printf '%s' "$comments_json" | jq -c \
		--arg label_at "$label_at" \
		--arg array_type "$array_type" \
		--arg retry_pattern "$retry_pattern" '
		(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
		elif type == $array_type then .
		else [] end)
		| [
			.[]
			| select(.created_at != null)
			| select((.created_at | fromdateiso8601) >= (($label_at | fromdateiso8601) - 5)
				and (.created_at | fromdateiso8601) <= (($label_at | fromdateiso8601) + 60))
			| select((.body // "") | test($retry_pattern))
			| {at: .created_at, body: (.body // "")}
		]
		| last // empty
	' 2>/dev/null) || breaker_event_json=""

	if [[ -z "$breaker_event_json" || "$breaker_event_json" == "null" ]]; then
		breaker_event_json=$(printf '%s' "$comments_json" | jq -c \
			--arg label_at "$label_at" \
			--arg array_type "$array_type" \
			--arg retry_pattern "$retry_pattern" '
			(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
			elif type == $array_type then .
			else [] end)
			| [
				.[]
				| select(.created_at != null)
				| select((.created_at | fromdateiso8601) <= (($label_at | fromdateiso8601) + 60))
				| select((.body // "") | test($retry_pattern))
				| {at: .created_at, body: (.body // "")}
			]
			| last // empty
		' 2>/dev/null) || breaker_event_json=""
	fi

	[[ -n "$breaker_event_json" && "$breaker_event_json" != "null" ]] || return 1
	printf '%s\n' "$breaker_event_json"
	return 0
}

#######################################
# Check if this breaker episode already consumed its automatic release retry.
#
# Args:
#   $1 - comments_json
#   $2 - breaker_at
#   $3 - current_version
#   $4 - breaker_version (optional; enables episode-scoped lineage guard)
# Returns: 0 if an auto-approval comment already consumed this retry.
#######################################
_nmr_retry_already_used_for_version() {
	local comments_json="$1"
	local breaker_at="$2"
	local current_version="$3"
	local breaker_version="${4:-}"

	[[ -n "$comments_json" && -n "$breaker_at" && -n "$current_version" ]] || return 1

	local approval_at_current_version_count
	approval_at_current_version_count=$(printf '%s' "$comments_json" | jq -r \
		--arg breaker_at "$breaker_at" \
		--arg current_version "$current_version" \
		--arg approval_marker "aidevops-signed-approval" '
		(if type == "array" and (.[0]? | type) == "array" then [.[][]]
		elif type == "array" then .
		else [] end)
		| [
			.[]
			| select(.created_at != null)
			| select((.created_at | fromdateiso8601) > ($breaker_at | fromdateiso8601))
			| select((.body // "") | contains($approval_marker))
			| select((.body // "") | contains($current_version))
		]
		| length
	' 2>/dev/null) || approval_at_current_version_count=0
	[[ "$approval_at_current_version_count" =~ ^[0-9]+$ ]] || approval_at_current_version_count=0

	if [[ "$approval_at_current_version_count" -gt 0 ]]; then
		return 0
	fi

	if [[ -n "$breaker_version" ]]; then
		local episode_retry_count
		episode_retry_count=$(printf '%s' "$comments_json" | jq -r \
			--arg breaker_at "$breaker_at" \
			--arg approval_marker "aidevops-signed-approval" \
			--arg retry_prefix "automated breaker retry allowed after aidevops upgrade ${breaker_version} ->" '
			(if type == "array" and (.[0]? | type) == "array" then [.[][]]
			elif type == "array" then .
			else [] end)
			| [
				.[]
				| select(.created_at != null)
				| select((.created_at | fromdateiso8601) > ($breaker_at | fromdateiso8601))
				| select((.body // "") | contains($approval_marker))
				| select((.body // "") | contains($retry_prefix))
			]
			| length
		' 2>/dev/null) || episode_retry_count=0
		[[ "$episode_retry_count" =~ ^[0-9]+$ ]] || episode_retry_count=0

		if [[ "$episode_retry_count" -gt 0 ]]; then
			return 0
		fi
	fi

	return 1
}

#######################################
# Decide if an automated breaker NMR should be allowed to retry because the
# deployed aidevops release is newer than the release that tripped the breaker.
#
# This is deliberately narrower than generic circuit-breaker preservation:
# only infra/capacity breaker markers qualify, manual holds and cost/stale
# retry-limit breakers stay pinned until cryptographic approval.
#
# Args:
#   $1 - issue_num
#   $2 - slug
#   $3 - label_at
# Stdout: short approval reason when retry is allowed.
# Returns: 0 allowed, 1 preserve NMR.
#######################################
_nmr_breaker_release_retry_reason() {
	local issue_num="$1"
	local slug="$2"
	local label_at="$3"

	[[ -n "$issue_num" && -n "$slug" && -n "$label_at" ]] || return 1

	local comments_json
	comments_json=$(gh api "repos/${slug}/issues/${issue_num}/comments" --paginate --slurp 2>/dev/null) || comments_json="[]"
	[[ -n "$comments_json" && "$comments_json" != "null" ]] || comments_json="[]"

	local retry_pattern='dispatch-backoff:rate_limit_nmr|cost-circuit-breaker:no_work_loop|dispatch-infrastructure-failure|dispatch-circuit-breaker:worker_recovery_loop'
	local breaker_event_json=""
	breaker_event_json=$(_nmr_retry_breaker_event_json "$comments_json" "$label_at" "$retry_pattern") || breaker_event_json=""
	[[ -n "$breaker_event_json" ]] || return 1

	local breaker_at="" breaker_body=""
	breaker_at=$(printf '%s' "$breaker_event_json" | jq -r '.at // ""' 2>/dev/null) || breaker_at=""
	breaker_body=$(printf '%s' "$breaker_event_json" | jq -r '.body // ""' 2>/dev/null) || breaker_body=""
	[[ -n "$breaker_at" ]] || return 1
	[[ -n "$breaker_body" ]] || return 1

	if printf '%s' "$breaker_body" | grep -q 'dispatch-backoff:rate_limit_nmr'; then
		local now_epoch="" label_epoch="" age_s="" cooldown_s="${AIDEVOPS_RATE_LIMIT_NMR_AUTO_RETRY_SECONDS:-1800}"
		now_epoch=$(date +%s 2>/dev/null || true)
		label_epoch=$(date -u -d "$label_at" '+%s' 2>/dev/null || TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$label_at" '+%s' 2>/dev/null || true)
		[[ "$cooldown_s" =~ ^[0-9]+$ ]] || cooldown_s=1800
		if [[ "$now_epoch" =~ ^[0-9]+$ && "$label_epoch" =~ ^[0-9]+$ ]]; then
			age_s=$((now_epoch - label_epoch))
			if [[ "$age_s" -ge "$cooldown_s" ]]; then
				printf 'rate-limit breaker cooldown expired after %ss (threshold %ss)\n' "$age_s" "$cooldown_s"
				return 0
			fi
		fi
	fi

	local breaker_version=""
	breaker_version=$(printf '%s' "$breaker_body" | grep -oE 'aidevops(_version)?[ =]v?[0-9]+(\.[0-9]+){1,3}|aidevops\.sh[^0-9]*v[0-9]+(\.[0-9]+){1,3}|version=[0-9]+(\.[0-9]+){1,3}' | tail -1 | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -1) || breaker_version=""
	[[ -n "$breaker_version" ]] || return 1

	local current_version=""
	current_version=$(_nmr_current_aidevops_version)
	[[ -n "$current_version" ]] || return 1

	if _nmr_retry_already_used_for_version "$comments_json" "$breaker_at" "$current_version" "$breaker_version"; then
		return 1
	fi

	local breaker_key="" current_key=""
	breaker_key=$(_nmr_version_sort_key "$breaker_version")
	current_key=$(_nmr_version_sort_key "$current_version")
	[[ -n "$breaker_key" && -n "$current_key" ]] || return 1

	if [[ "$current_key" > "$breaker_key" ]]; then
		printf 'automated breaker retry allowed after aidevops upgrade %s -> %s\n' \
			"$breaker_version" "$current_version"
		return 0
	fi

	return 1
}

#######################################
# Classify an NMR episode into a stable reason code. Explicit structured
# markers win; legacy breaker text is mapped without copying prose or paths.
# Stdout: {code,class,source,revalidate_after_seconds,requires_crypto}
#######################################
_nmr_reason_metadata_from_comments() {
	local comments_json="$1"
	local revalidate_seconds="$NMR_TEMPORARY_REVALIDATE_SECONDS"
	[[ "$revalidate_seconds" =~ ^[0-9]+$ ]] || revalidate_seconds=3600
	printf '%s' "$comments_json" | jq -c --argjson revalidate "$revalidate_seconds" \
		-f "$NMR_REASON_FILTER" 2>/dev/null || \
		_nmr_metadata_json "$NMR_REASON_AUTHORITY" "$NMR_CLASS_GENUINE_AUTHORITY" "$NMR_SOURCE_DEFAULT" true
	return 0
}

_nmr_reason_metadata() {
	local issue_num="$1"
	local slug="$2"
	local comments_json="[]"
	local comments_path=""
	comments_path=$(_nmr_issue_api_path "$issue_num" "$slug" "$NMR_API_COMMENTS_SUFFIX")
	comments_json=$(gh api "$comments_path" --paginate --slurp 2>/dev/null) || comments_json="[]"
	_nmr_reason_metadata_from_comments "$comments_json"
	return 0
}

_nmr_revalidation_due() {
	local metadata_json="$1"
	local label_at="$2"
	local now_epoch=""
	local label_epoch=""
	local after_seconds=""
	now_epoch=$(date +%s 2>/dev/null || true)
	label_epoch=$(date -u -d "$label_at" '+%s' 2>/dev/null || TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$label_at" '+%s' 2>/dev/null || true)
	after_seconds=$(printf '%s' "$metadata_json" | jq -r '.revalidate_after_seconds // 0' 2>/dev/null) || after_seconds=0
	[[ "$now_epoch" =~ ^[0-9]+$ && "$label_epoch" =~ ^[0-9]+$ && "$after_seconds" =~ ^[0-9]+$ ]] || return 1
	[[ $((now_epoch - label_epoch)) -ge "$after_seconds" ]]
	return $?
}

_nmr_temporary_assumption_resolved() {
	local issue_num="$1"
	local slug="$2"
	local code="$3"
	local label_at="$4"
	if [[ "$code" == "transient_infrastructure" ]]; then
		local retry_reason=""
		retry_reason=$(_nmr_breaker_release_retry_reason "$issue_num" "$slug" "$label_at") || retry_reason=""
		if [[ -n "$retry_reason" ]]; then
			printf '%s\n' "$retry_reason"
			return 0
		fi
	fi

	local issue_json="{}"
	local issue_path=""
	issue_path=$(_nmr_issue_api_path "$issue_num" "$slug")
	issue_json=$(gh api "$issue_path" 2>/dev/null) || issue_json="{}"
	if [[ "$code" == "missing_context" ]] && printf '%s' "$issue_json" | jq -e '
		((.body // "") | contains("## Worker Guidance")) and
		((.body // "") | contains("### Verification"))
	' >/dev/null 2>&1; then
		printf 'worker guidance and verification are now present\n'
		return 0
	fi

	local comments_json="[]"
	local comments_path=""
	comments_path=$(_nmr_issue_api_path "$issue_num" "$slug" "$NMR_API_COMMENTS_SUFFIX")
	comments_json=$(gh api "$comments_path" --paginate --slurp 2>/dev/null) || comments_json="[]"
	if printf '%s' "$comments_json" | jq -e -f "$NMR_TRUSTED_RESOLUTION_FILTER" >/dev/null 2>&1; then
		printf 'trusted revalidation evidence resolved the temporary assumption\n'
		return 0
	fi
	return 1
}

_nmr_record_revalidation_state() {
	local issue_num="$1"
	local slug="$2"
	local metadata_json="$3"
	local label_at="$4"
	local status="$5"
	local state_dir="${NMR_REVALIDATION_STATE_FILE%/*}"
	[[ "$state_dir" != "$NMR_REVALIDATION_STATE_FILE" ]] || return 0
	mkdir -p "$state_dir" 2>/dev/null || return 0
	local current="{}"
	if [[ -f "$NMR_REVALIDATION_STATE_FILE" ]]; then
		current=$(cat "$NMR_REVALIDATION_STATE_FILE" 2>/dev/null) || current="{}"
	fi
	printf '%s' "$current" | jq empty >/dev/null 2>&1 || current="{}"
	local key="${slug}#${issue_num}"
	local tmp_file=""
	tmp_file=$(mktemp "${state_dir}/.nmr-revalidation.XXXXXX") || return 0
	printf '%s' "$current" | jq --arg key "$key" --arg label_at "$label_at" --arg status "$status" \
		--argjson metadata "$metadata_json" -f "$NMR_STATE_RECORD_FILTER" \
		>"$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; return 0; }
	mv "$tmp_file" "$NMR_REVALIDATION_STATE_FILE" 2>/dev/null || rm -f "$tmp_file"
	return 0
}

_nmr_emit_decision_packet() {
	local issue_num="$1"
	local slug="$2"
	local reason_code="$3"
	local marker="nmr-decision-packet reason=${reason_code}"
	local prior_count="0"
	local comments_path=""
	comments_path=$(_nmr_issue_api_path "$issue_num" "$slug" "$NMR_API_COMMENTS_SUFFIX")
	prior_count=$(gh api "$comments_path" --paginate \
		--jq "[.[] | select((.body // \"\") | contains(\"${marker}\"))] | length" 2>/dev/null) || prior_count=0
	[[ "$prior_count" =~ ^[0-9]+$ ]] || prior_count=0
	[[ "$prior_count" -eq 0 ]] || return 0
	gh_issue_comment "$issue_num" --repo "$slug" --body "<!-- ${marker} -->
## Maintainer decision required

- Reason: ${reason_code}
- Evidence: the current NMR reason is classified as genuine authority, not a transient diagnostic or infrastructure condition.
- Options: approve with \`sudo aidevops approve issue ${issue_num} ${slug}\`, or document the rejected/alternative direction.

Automation will preserve this gate and will not treat elapsed time as approval." 2>/dev/null || true
	return 0
}

_nmr_latest_event_json() {
	local issue_num="$1"
	local slug="$2"
	local timeline_path=""
	timeline_path=$(_nmr_issue_api_path "$issue_num" "$slug" "/timeline")
	gh api "$timeline_path" --paginate --slurp \
		2>/dev/null | jq -c -f "$NMR_LATEST_EVENT_FILTER" 2>/dev/null
	return $?
}

_nmr_evaluate_reason_metadata() {
	local issue_num="$1"
	local slug="$2"
	local nmr_at="$3"
	_NMR_REASON_ACTION="continue"
	_NMR_REASON_OVERRIDE=""
	[[ -n "$nmr_at" ]] || return 0

	local reason_metadata=""
	local reason_code=""
	local reason_class=""
	local reason_source=""
	reason_metadata=$(_nmr_reason_metadata "$issue_num" "$slug")
	reason_code=$(printf '%s' "$reason_metadata" | jq -r --arg fallback "$NMR_REASON_AUTHORITY" '.code // $fallback' 2>/dev/null) || reason_code="$NMR_REASON_AUTHORITY"
	reason_class=$(printf '%s' "$reason_metadata" | jq -r --arg fallback "$NMR_CLASS_GENUINE_AUTHORITY" '.class // $fallback' 2>/dev/null) || reason_class="$NMR_CLASS_GENUINE_AUTHORITY"
	reason_source=$(printf '%s' "$reason_metadata" | jq -r --arg fallback "$NMR_SOURCE_DEFAULT" '.source // $fallback' 2>/dev/null) || reason_source="$NMR_SOURCE_DEFAULT"
	if [[ "$reason_class" == "$NMR_CLASS_TEMPORARY" ]]; then
		_nmr_record_revalidation_state "$issue_num" "$slug" "$reason_metadata" "$nmr_at" "scheduled" || true
		if _nmr_revalidation_due "$reason_metadata" "$nmr_at"; then
			local resolved_reason=""
			resolved_reason=$(_nmr_temporary_assumption_resolved "$issue_num" "$slug" "$reason_code" "$nmr_at") || resolved_reason=""
			if [[ -n "$resolved_reason" ]]; then
				#aidevops:trust-boundary -- only trusted markers and existing breaker checks can release temporary NMR
				_NMR_REASON_ACTION="auto"
				_NMR_REASON_OVERRIDE="temporary NMR revalidated (${reason_code}): ${resolved_reason}"
				_nmr_record_revalidation_state "$issue_num" "$slug" "$reason_metadata" "$nmr_at" "automatable" || true
				return 0
			fi
			_nmr_record_revalidation_state "$issue_num" "$slug" "$reason_metadata" "$nmr_at" "rechecked-unresolved" || true
		fi
		_NMR_REASON_ACTION="preserve"
		return 0
	fi
	if [[ "$reason_source" != "$NMR_SOURCE_DEFAULT" ]]; then
		_nmr_record_revalidation_state "$issue_num" "$slug" "$reason_metadata" "$nmr_at" "$NMR_STATUS_HUMAN_AUTHORITY" || true
		_nmr_emit_decision_packet "$issue_num" "$slug" "$reason_code" || true
		_NMR_REASON_ACTION="preserve"
	fi
	return 0
}

#######################################
# Check if the needs-maintainer-review label was most recently applied
# by the maintainer themselves (indicating a manual hold), OR by a
# circuit breaker trip (which must be treated as a hold even though
# the token actor is the maintainer).
#
# GH#18671 / t2386: the pulse runs as the maintainer's GitHub token,
# so `actor.login == maintainer` matches all three cases:
#   1. Human maintainer clicks the label (manual hold)
#   2. Pulse scanner applies default NMR at creation (auto-clear OK)
#   3. Circuit breaker trips (t2007 cost / t2008 stale) — MUST preserve
#   4. Security-sensitive automation applies NMR — MUST preserve
#
# Cases 1, 3, and 4 are "preserve NMR" (return 0); case 2 is
# "auto-clear OK" (return 1). The split is driven by companion helpers:
# `_nmr_application_has_automation_signature` (creation defaults),
# `_nmr_application_is_circuit_breaker_trip` (breaker trips), and
# `_nmr_application_is_security_sensitive` (security review boundary).
# See t2386 brief for the #19756 infinite-loop incident that motivated
# the automation split.
#
# Arguments:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#   $3 - maintainer : maintainer GitHub login
#
# Returns 0 if the maintainer applied NMR AND no creation-default
#           signature is present (manual hold or breaker trip — do NOT
#           auto-approve).
# Returns 1 if NMR was applied by a scanner default or the actor is
#           unknown (auto-approve OK).
#######################################
_nmr_applied_by_maintainer() {
	local issue_num="$1"
	local slug="$2"
	local maintainer="$3"
	_NMR_AUTO_APPROVAL_REASON_OVERRIDE=""

	[[ -n "$issue_num" && -n "$slug" && -n "$maintainer" ]] || return 1

	# Fetch both actor and creation timestamp of the latest NMR label event.
	local nmr_event_json=""
	nmr_event_json=$(_nmr_latest_event_json "$issue_num" "$slug") || nmr_event_json=""

	local nmr_actor nmr_at
	nmr_actor=$(printf '%s' "$nmr_event_json" | jq -r '.actor // ""' 2>/dev/null) || nmr_actor=""
	nmr_at=$(printf '%s' "$nmr_event_json" | jq -r '.at // ""' 2>/dev/null) || nmr_at=""

	_nmr_evaluate_reason_metadata "$issue_num" "$slug" "$nmr_at"
	case "$_NMR_REASON_ACTION" in
		auto)
			_NMR_AUTO_APPROVAL_REASON_OVERRIDE="$_NMR_REASON_OVERRIDE"
			echo "[pulse-wrapper] _nmr_applied_by_maintainer: #${issue_num} in ${slug} — temporary NMR revalidated; allowing trusted maintainer-authored retry" >>"$LOGFILE"
			return 1
			;;
		preserve)
			echo "[pulse-wrapper] _nmr_applied_by_maintainer: #${issue_num} in ${slug} — reason-coded NMR remains gated" >>"$LOGFILE"
			return 0
			;;
	esac

	# Breaker signatures are authoritative regardless of the token actor. Pulse can
	# run under any trusted maintainer/member account, so actor-gating this check
	# lets a peer runner's dispatch-infrastructure/no_work breaker be auto-cleared
	# by maintainer auto-approval and re-enter the loop.
	if [[ -n "$nmr_at" ]]; then
		if _nmr_application_is_circuit_breaker_trip "$issue_num" "$slug" "$nmr_at"; then
			local release_retry_reason=""
			release_retry_reason=$(_nmr_breaker_release_retry_reason "$issue_num" "$slug" "$nmr_at") || release_retry_reason=""
			if [[ -n "$release_retry_reason" ]]; then
				_NMR_AUTO_APPROVAL_REASON_OVERRIDE="$release_retry_reason"
				echo "[pulse-wrapper] _nmr_applied_by_maintainer: #${issue_num} in ${slug} — ${release_retry_reason}; allowing one auto-approval retry" >>"$LOGFILE"
				return 1
			fi
			echo "[pulse-wrapper] _nmr_applied_by_maintainer: #${issue_num} in ${slug} — circuit breaker tripped by actor=${nmr_actor:-unknown} — PRESERVING NMR, requires 'sudo aidevops approve issue ${issue_num} ${slug}' (t2386/t3566)" >>"$LOGFILE"
			# t3049: check if a subsequent worker produced a clean approved PR
			# that resolves the stale-recovery false positive. Posts a one-shot
			# notification to the maintainer if so. Does NOT clear NMR.
			_notify_stale_recovery_resolved_by_pr "$issue_num" "$slug" "$nmr_at" || true
			return 0
		fi
	fi

	if [[ -n "$nmr_at" ]]; then
		if _nmr_application_has_breaker_history "$issue_num" "$slug" "$nmr_at"; then
			local history_retry_reason=""
			history_retry_reason=$(_nmr_breaker_release_retry_reason "$issue_num" "$slug" "$nmr_at") || history_retry_reason=""
			if [[ -n "$history_retry_reason" ]]; then
				_NMR_AUTO_APPROVAL_REASON_OVERRIDE="$history_retry_reason"
				echo "[pulse-wrapper] _nmr_applied_by_maintainer: #${issue_num} in ${slug} — prior breaker marker found; ${history_retry_reason}; allowing one auto-approval retry" >>"$LOGFILE"
				return 1
			fi
			echo "[pulse-wrapper] _nmr_applied_by_maintainer: #${issue_num} in ${slug} — prior circuit breaker marker remains active after latest NMR relabel by actor=${nmr_actor:-unknown} — PRESERVING NMR, requires 'sudo aidevops approve issue ${issue_num} ${slug}' (t2386/t3566)" >>"$LOGFILE"
			_notify_stale_recovery_resolved_by_pr "$issue_num" "$slug" "$nmr_at" || true
			return 0
		fi
	fi

	if _nmr_application_is_security_sensitive "$issue_num" "$slug"; then
		local security_metadata=""
		security_metadata=$(_nmr_metadata_json "security" "$NMR_CLASS_GENUINE_AUTHORITY" "security-label" true)
		_nmr_record_revalidation_state "$issue_num" "$slug" "$security_metadata" "$nmr_at" "$NMR_STATUS_HUMAN_AUTHORITY" || true
		_nmr_emit_decision_packet "$issue_num" "$slug" "security" || true
		echo "[pulse-wrapper] _nmr_applied_by_maintainer: #${issue_num} in ${slug} — security-sensitive label present — PRESERVING NMR, requires 'sudo aidevops approve issue ${issue_num} ${slug}'" >>"$LOGFILE"
		return 0
	fi

	if [[ "$nmr_actor" != "$maintainer" ]]; then
		return 1
	fi

	# Actor matches the maintainer. Two remaining possibilities:
	#   1. Creation-default signature (scanner applied NMR at creation
	#      time) → auto-approve OK, return 1.
	#   2. No signature → genuine manual hold, return 0.
	if [[ -n "$nmr_at" ]]; then
		if _nmr_application_has_automation_signature "$issue_num" "$slug" "$nmr_at"; then
			echo "[pulse-wrapper] _nmr_applied_by_maintainer: #${issue_num} in ${slug} — actor=${maintainer} but creation-default signature detected — classifying as automation-applied (GH#18671)" >>"$LOGFILE"
			return 1
		fi
	fi

	local authority_metadata=""
	authority_metadata=$(_nmr_metadata_json "$NMR_REASON_AUTHORITY" "$NMR_CLASS_GENUINE_AUTHORITY" "manual-hold" true)
	_nmr_record_revalidation_state "$issue_num" "$slug" "$authority_metadata" "$nmr_at" "$NMR_STATUS_HUMAN_AUTHORITY" || true
	_nmr_emit_decision_packet "$issue_num" "$slug" "$NMR_REASON_AUTHORITY" || true
	return 0
}

#######################################
# Post a one-shot remediation comment when a maintainer manually removes
# the needs-maintainer-review label but the ever-NMR history flag is still
# set and no cryptographic approval exists (GH#20682).
#
# Without this, pulse silently skips dispatch with:
#   [pulse-wrapper] dispatch_with_dedup: BLOCKED #N — requires cryptographic
#   approval (ever-NMR)
# ...and the maintainer has no user-facing signal that cryptographic approval
# is still required. This function posts an explanatory comment exactly once.
#
# Detection logic (all four conditions must hold):
#   1. Label needs-maintainer-review is absent (label was removed by human)
#   2. ever-NMR history is set (issue_was_ever_nmr returns true)
#   3. No cryptographic approval comment exists (approval-helper verify != VERIFIED)
#   4. No prior <!-- ever-nmr-remediation --> marker exists (idempotency guard)
#
# Arguments:
#   $1 - issue_number  : GitHub issue number
#   $2 - repo_slug     : owner/repo
#
# Returns: 0 always (fail-open — a missed comment is better than a broken
#          dispatch loop).
#######################################
notify_ever_nmr_without_approval() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 0

	# Condition 1: label must be absent. Callers that have already determined
	# the label is absent pass us; callers can also call us directly and we
	# verify here.
	local has_nmr_label
	has_nmr_label=$(gh api "repos/${repo_slug}/issues/${issue_number}" \
		--jq '.labels | map(.name) | index("needs-maintainer-review") != null' \
		2>/dev/null) || has_nmr_label="false"
	if [[ "$has_nmr_label" == "true" ]]; then
		# Label still present — no remediation needed, block is visible to user.
		return 0
	fi

	# Condition 2: issue must have ever-NMR history (timeline check via cache).
	if ! issue_was_ever_nmr "$issue_number" "$repo_slug"; then
		return 0
	fi

	# Condition 3: no cryptographic approval exists.
	# Delegate to issue_has_required_approval with known_status="true" (ever-NMR
	# confirmed above) so that only the approval helper is consulted, short-
	# circuiting the redundant timeline API call for ever-NMR provenance.
	if issue_has_required_approval "$issue_number" "$repo_slug" "true"; then
		# Approved — block will clear on next dispatch cycle.
		return 0
	fi

	# Condition 4: idempotency guard — never post twice.
	local already_notified
	already_notified=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" --paginate \
		--jq '[.[] | select(.body | test("ever-nmr-remediation"))] | length' \
		2>/dev/null) || already_notified=0
	[[ "$already_notified" =~ ^[0-9]+$ ]] || already_notified=0
	if [[ "$already_notified" -gt 0 ]]; then
		echo "[pulse-wrapper] notify_ever_nmr_without_approval: #${issue_number} in ${repo_slug} — remediation comment already posted, skipping" >>"$LOGFILE"
		return 0
	fi

	# All four conditions met — post the remediation comment.
	echo "[pulse-wrapper] notify_ever_nmr_without_approval: #${issue_number} in ${repo_slug} — posting ever-NMR remediation comment (GH#20682)" >>"$LOGFILE"

	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "<!-- ever-nmr-remediation -->
> Label \`needs-maintainer-review\` was removed, but the \`ever-NMR\` history flag is still set. Pulse will continue to skip dispatch until cryptographic approval lands:
>
> \`\`\`
> sudo aidevops approve issue ${issue_number} ${repo_slug}
> \`\`\`
>
> This gate cannot be bypassed by label manipulation (security design — see \`reference/auto-merge.md\` NMR section)." \
		2>/dev/null || {
		echo "[pulse-wrapper] notify_ever_nmr_without_approval: #${issue_number} in ${repo_slug} — failed to post remediation comment" >>"$LOGFILE"
	}

	return 0
}

#######################################
# Verify that this runner is allowed to post maintainer-authority approval
# comments for the upstream repo.
#
# <!-- aidevops:trust-boundary -->
# Local repos.json can be wrong or copied to an external contributor's machine.
# Before automation posts `aidevops-signed-approval` or says "maintainer is
# author", self-validate against GitHub: the current token actor must have
# write/maintain/admin permission on the target repo, and the issue author must
# be an upstream OWNER/MEMBER with the expected maintainer login.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - expected maintainer login from repos.json
#   $4 - issue author login from the list response
# Returns: 0 when approval comments may be posted, 1 otherwise.
#######################################
_nmr_current_actor_can_post_maintainer_approval() {
	local issue_num="$1"
	local slug="$2"
	local maintainer="$3"
	local listed_author="$4"

	[[ -n "$issue_num" && -n "$slug" && -n "$maintainer" && -n "$listed_author" ]] || return 1
	[[ "$listed_author" == "$maintainer" ]] || return 1

	local issue_meta
	local issue_api_path
	printf -v issue_api_path 'repos/%s/issues/%s' "$slug" "$issue_num"
	issue_meta=$(gh api "$issue_api_path" 2>/dev/null) || issue_meta=""
	[[ -n "$issue_meta" ]] || return 1

	local issue_author
	local issue_assoc
	issue_author=$(printf '%s' "$issue_meta" | jq -r '.user.login // empty' 2>/dev/null) || issue_author=""
	issue_assoc=$(printf '%s' "$issue_meta" | jq -r '.author_association // "NONE"' 2>/dev/null) || issue_assoc="NONE"
	[[ "$issue_author" == "$maintainer" ]] || return 1
	case "$issue_assoc" in
	OWNER | MEMBER) ;;
	*) return 1 ;;
	esac

	local actor
	actor=$(gh api user --jq '.login // empty' 2>/dev/null) || actor=""
	[[ -n "$actor" ]] || return 1

	local actor_permission
	# #aidevops:trust-boundary — maintainer approval posting requires confirmed
	# write+ access; transient permission lookup failures fail closed.
	_gh_collaborator_permission_lookup "$slug" "$actor" actor_permission || return 1
	case "$actor_permission" in
	admin | maintain | write) return 0 ;;
	*) return 1 ;;
	esac
}

#######################################
# t3049: Evaluate linked OPEN PRs against the trust boundary gates and return
# the number of the first qualifying PR, or empty string if none qualifies.
#
# <!-- aidevops:trust-boundary -->
# Self-validates each gate: PR createdAt > NMR labelledAt, APPROVED review,
# OWNER/MEMBER authorAssociation, origin:worker or origin:interactive label,
# all non-maintainer-gate CI SUCCESS.
#
# Arguments:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#   $3 - nmr_at     : ISO8601 timestamp when NMR was applied
#
# Outputs: PR number on stdout (empty if no match).
# Returns: 0 always.
#######################################
_find_qualifying_pr_for_stale_recovery() {
	local issue_num="$1"
	local slug="$2"
	local nmr_at="$3"

	[[ -n "$nmr_at" ]] || return 0

	# reviewDecision is policy-level GraphQL state and cannot be reconstructed
	# from REST review history. Use a fixed-shape search query that reports its
	# own calibrated one-point cost instead of native gh pr list, whose cost is
	# otherwise unattributable (GH#27777). headRefOid feeds REST check-runs below.
	local query_string="repo:${slug} is:pr is:open Resolves #${issue_num} in:body"
	local response="" reported_cost="" pr_json="[]"
	# shellcheck disable=SC2016
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 AIDEVOPS_GH_ROUTE_DECISION="pulse-nmr-pr-search-exact-cost" \
		gh api graphql -F queryString="$query_string" -f query='
		query($queryString: String!) {
			search(type: ISSUE, query: $queryString, first: 10) {
				nodes {
					... on PullRequest {
						number
						reviewDecision
						headRefOid
						authorAssociation
						labels(first: 100) { nodes { name } pageInfo { hasNextPage } }
						createdAt
					}
				}
			}
			rateLimit { cost }
		}
	' 2>/dev/null) || response=""
	[[ -n "$response" ]] || return 0
	reported_cost=$(printf '%s' "$response" | jq -r '.data.rateLimit.cost // empty' 2>/dev/null) || reported_cost=""
	[[ "$reported_cost" == "1" ]] || return 0
	pr_json=$(printf '%s' "$response" | jq -c '
		.data.search.nodes
		| if type != "array" then error("search nodes must be an array") else . end
		| if any(.[]?; (.labels.pageInfo.hasNextPage // false) == true)
			then error("PR label page is incomplete") else . end
		| map({
			number,
			reviewDecision,
			headRefOid,
			authorAssociation,
			labels: (.labels.nodes // []),
			createdAt
		})
	' 2>/dev/null) || pr_json="[]"
	[[ -n "$pr_json" && "$pr_json" != "null" ]] || pr_json="[]"

	local candidate_prs
	candidate_prs=$(printf '%s' "$pr_json" | jq -r \
		--arg nmr_at "$nmr_at" \
		--arg approved "APPROVED" \
		--arg owner "OWNER" \
		--arg member "MEMBER" \
		--arg origin_worker "origin:worker" \
		--arg origin_interactive "origin:interactive" '
		($nmr_at | fromdateiso8601) as $target_ts
		|
		.[]?
		| select(.createdAt != null)
		| select((.createdAt | fromdateiso8601) > $target_ts)
		| select(.reviewDecision == $approved)
		| select(.authorAssociation == $owner or .authorAssociation == $member)
		| select([.labels[]?.name] | any(. == $origin_worker or . == $origin_interactive))
		| select(.headRefOid != null and .headRefOid != "")
		| [.number, .headRefOid]
		| @tsv
	' 2>/dev/null) || candidate_prs=""
	[[ -n "$candidate_prs" ]] || return 0

	local pr_num="" pr_sha=""
	while IFS=$'\t' read -r pr_num pr_sha; do
		[[ -n "$pr_num" && -n "$pr_sha" ]] || continue

		# GH#21799: All non-maintainer-gate CI checks must have a passing
		# conclusion. Fetch via REST check-runs (separate from GraphQL pool).
		local check_runs_json
		check_runs_json=$(gh_pr_check_runs_rest "$slug" "$pr_sha" 2>/dev/null) || check_runs_json=""
		# Empty output → /check-runs API failure → fail-closed (skip this PR).
		[[ -n "$check_runs_json" ]] || continue
		local failing_checks
		failing_checks=$(printf '%s' "$check_runs_json" | jq -r \
			'[.[]? | select(.name != null) | select(.name | test("Maintainer Review"; "i") | not) | select((.conclusion // "" | ascii_upcase) != "SUCCESS" and (.conclusion // "" | ascii_upcase) != "NEUTRAL" and (.conclusion // "" | ascii_upcase) != "SKIPPED")] | length' \
			2>/dev/null) || failing_checks=0
		[[ "$failing_checks" =~ ^[0-9]+$ ]] || failing_checks=0
		[[ "$failing_checks" -le 0 ]] || continue

		# All gates passed — output the PR number.
		printf '%s' "$pr_num"
		return 0
	done <<<"$candidate_prs"

	return 0
}

#######################################
# t3049: Post a one-shot notification when a stale-recovery NMR is resolved
# by a subsequent worker producing an APPROVED PR.
#
# When stale-recovery applies NMR (via stale-recovery-tick:escalated), a
# subsequent worker may still produce a clean PR. If that PR is APPROVED with
# all non-maintainer-gate CI green and authored by OWNER/MEMBER with
# origin:worker or origin:interactive, the maintainer only needs to run
# `sudo aidevops approve issue N` to unblock the merge — but has no signal.
# This function posts exactly that signal, once.
#
# <!-- aidevops:trust-boundary -->
# Self-validates: PR author association (OWNER/MEMBER only), PR origin label
# (origin:worker or origin:interactive only), PR createdAt > NMR labelledAt,
# reviewDecision==APPROVED, all non-maintainer-gate CI SUCCESS.
# Does NOT trust upstream checks — each gate is evaluated at invocation time.
#
# SECURITY: NMR is NOT auto-cleared. The notification only prompts the
# maintainer to run the cryptographic approval command. The bypass surface
# is closed because:
#   - Only OWNER/MEMBER-authored PRs qualify (no contributor injection)
#   - Only origin:worker/origin:interactive PRs qualify (no takeover)
#   - Maintainer-gate is not auto-cleared — human must run crypto approval
#
# Arguments:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#   $3 - nmr_at     : ISO8601 timestamp when NMR was applied
#
# Returns: 0 always (fail-open — a missed notification is better than a broken
#          approval loop).
#######################################
_notify_stale_recovery_resolved_by_pr() {
	local issue_num="$1"
	local slug="$2"
	local nmr_at="$3"

	[[ -n "$issue_num" && -n "$slug" && -n "$nmr_at" ]] || return 0

	# Shared API path — constructed via printf to avoid string-literal ratchet regression
	local comments_api
	printf -v comments_api 'repos/%s/issues/%s/comments' "$slug" "$issue_num"
	local json_null='null'

	# Gate 1/2: Fetch comments once, then evaluate stale-recovery eligibility
	# and idempotency from the same result. Cost-circuit-breaker:fired and
	# cost-circuit-breaker:no_work_loop indicate budget/infra problems where
	# merging is itself unsafe.
	local stale_marker='stale-recovery-tick:escalated'
	local breaker_pattern='cost-circuit-breaker:fired|cost-circuit-breaker:no_work_loop'
	local notice_marker='nmr-stale-recovery-resolution-notice'
	local comments_json comment_state
	comments_json=$(gh api "$comments_api" --paginate --slurp 2>/dev/null) || comments_json="[]"
	[[ -n "$comments_json" && "$comments_json" != "$json_null" ]] || comments_json="[]"
	comment_state=$(printf '%s' "$comments_json" | jq -r \
		--arg array_type "array" \
		--arg stale_marker "$stale_marker" \
		--arg breaker_pattern "$breaker_pattern" \
		--arg notice_marker "$notice_marker" '
			(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
			elif type == $array_type then .
			else [] end)
			|
			[
				([
					.[]
					| select((.body? // empty) | test($stale_marker))
					| select(((.body? // empty) | test($breaker_pattern)) | not)
				] | length),
				([
					.[]
					| select((.body? // empty) | test($notice_marker))
				] | length)
			]
			| @tsv
		' \
		2>/dev/null) || comment_state=""

	local has_stale_recovery=0 already_notified=0
	local page_stale_recovery="" page_already_notified=""
	while IFS=$'\t' read -r page_stale_recovery page_already_notified; do
		[[ "$page_stale_recovery" =~ ^[0-9]+$ ]] || page_stale_recovery=0
		[[ "$page_already_notified" =~ ^[0-9]+$ ]] || page_already_notified=0
		has_stale_recovery=$((has_stale_recovery + page_stale_recovery))
		already_notified=$((already_notified + page_already_notified))
	done <<<"$comment_state"

	if [[ "$has_stale_recovery" -le 0 ]]; then
		return 0
	fi

	if [[ "$already_notified" -gt 0 ]]; then
		echo "[pulse-wrapper] _notify_stale_recovery_resolved_by_pr: #${issue_num} in ${slug} — notification already posted, skipping" >>"$LOGFILE"
		return 0
	fi

	# Gate 3: Find a qualifying linked PR via the extracted helper.
	local matching_pr
	matching_pr=$(_find_qualifying_pr_for_stale_recovery "$issue_num" "$slug" "$nmr_at")
	if [[ -z "$matching_pr" ]]; then
		return 0
	fi

	# Post the one-shot notification.
	echo "[pulse-wrapper] _notify_stale_recovery_resolved_by_pr: #${issue_num} in ${slug} — PR #${matching_pr} qualifies, posting notification" >>"$LOGFILE"

	gh_issue_comment "$issue_num" --repo "$slug" \
		--body "<!-- nmr-stale-recovery-resolution-notice -->
PR #${matching_pr} is APPROVED with all quality/security gates green. To merge, run:

\`\`\`
sudo aidevops approve issue ${issue_num} ${slug}
\`\`\`

This issue's NMR was applied by stale-recovery (t2008) — the cryptographic approval clears it and the merge gate flips to PASS." \
		2>/dev/null || {
		echo "[pulse-wrapper] _notify_stale_recovery_resolved_by_pr: #${issue_num} in ${slug} — failed to post notification" >>"$LOGFILE"
	}

	return 0
}

#######################################
# t2845: Handle knowledge-review issue promotion after cryptographic approval.
#
# When auto_approve_maintainer_issues clears NMR on a kind:knowledge-review
# issue, this function extracts the source_id from the body marker
# (<!-- aidevops:knowledge-review source_id:xxx -->), calls
# knowledge-review-helper.sh promote <source_id> to move staging -> sources,
# posts a closing comment, and closes the issue.
#
# Arguments:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#
# Returns: 0 always (fail-open — a missed promotion is better than a broken
#          approval loop).
#######################################
_handle_knowledge_review_promotion() {
	local issue_num="$1"
	local slug="$2"

	[[ -n "$issue_num" && -n "$slug" ]] || return 0

	# Shared API path (avoids repeated literal, which would trip the string-literal ratchet)
	local issue_api="repos/${slug}/issues/${issue_num}"

	# Only act on kind:knowledge-review issues
	local has_kr_label
	has_kr_label=$(gh api "$issue_api" \
		--jq '.labels | map(.name) | map(select(. == "kind:knowledge-review")) | length' \
		2>/dev/null) || has_kr_label=0
	[[ "$has_kr_label" =~ ^[0-9]+$ ]] || has_kr_label=0
	[[ "$has_kr_label" -gt 0 ]] || return 0

	# Extract source_id from body marker <!-- aidevops:knowledge-review source_id:xxx -->
	local issue_body
	issue_body=$(gh api "$issue_api" \
		--jq '.body // ""' 2>/dev/null) || issue_body=""

	local source_id
	source_id=$(printf '%s' "$issue_body" \
		| grep -oE 'source_id:[a-zA-Z0-9_.-]+' \
		| head -1 \
		| cut -d: -f2 2>/dev/null) || source_id=""

	if [[ -z "$source_id" ]]; then
		echo "[pulse-wrapper] _handle_knowledge_review_promotion: #${issue_num} in ${slug} — no source_id in body, skipping" >>"$LOGFILE"
		return 0
	fi

	# Locate knowledge-review-helper.sh in the deployed agents dir
	local kr_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/knowledge-review-helper.sh"
	if [[ ! -f "$kr_helper" ]]; then
		echo "[pulse-wrapper] _handle_knowledge_review_promotion: helper not found at ${kr_helper}" >>"$LOGFILE"
		return 0
	fi

	# Promote source from staging -> sources
	if ! bash "$kr_helper" promote "$source_id" 2>/dev/null; then
		echo "[pulse-wrapper] _handle_knowledge_review_promotion: #${issue_num} — promote '${source_id}' failed, issue stays open" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] _handle_knowledge_review_promotion: #${issue_num} in ${slug} — promoted '${source_id}' to sources/" >>"$LOGFILE"

	# Post closing comment then close the issue
	gh_issue_comment "$issue_num" --repo "$slug" \
		--body "<!-- aidevops:knowledge-review-complete -->
Knowledge source \`${source_id}\` promoted from staging to \`sources/\` after cryptographic approval. Audit log updated." \
		2>/dev/null || true

	gh issue close "$issue_num" --repo "$slug" 2>/dev/null || true
	echo "[pulse-wrapper] _handle_knowledge_review_promotion: #${issue_num} in ${slug} — closed" >>"$LOGFILE"
	return 0
}

#######################################
# Restore the complete dispatchable state after trusted NMR approval.
# Stale escalation removes both core status labels and auto-dispatch, so the
# approval transition must not depend on a racing recovery writer.
# Args: issue number, repo slug
#######################################
_nmr_restore_dispatchable_state() {
	local issue_num="$1"
	local slug="$2"
	if declare -F set_issue_status >/dev/null 2>&1; then
		set_issue_status "$issue_num" "$slug" "available" \
			--remove-label "needs-maintainer-review" \
			--add-label "auto-dispatch" >/dev/null 2>&1
		return $?
	fi
	gh issue edit "$issue_num" --repo "$slug" \
		--remove-label "needs-maintainer-review" \
		--add-label "status:available" \
		--add-label "auto-dispatch" >/dev/null 2>&1
	return $?
}

#######################################
# Auto-approve needs-maintainer-review issues using cryptographic
# signature verification (t1894, replaces GH#16842 comment-based check).
#
# The review gate exists for external contributions. Approval requires
# a cryptographically signed comment posted via `sudo aidevops approve
# issue <number>`. This ensures only a human with the system password
# (and root access to the approval signing key) can approve issues.
#
# Fallback: maintainer-authored issues are still auto-approved (the
# maintainer wouldn't gate their own issues), UNLESS the maintainer
# manually applied NMR themselves — that signals an intentional hold
# and must be preserved. Comment-based approval is removed — workers
# share the same GitHub account so any comment from the account is
# indistinguishable from a human comment.
#######################################
auto_approve_maintainer_issues() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_approved=0
	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"

	while IFS='|' read -r slug maintainer; do
		[[ -n "$slug" && -n "$maintainer" ]] || continue

		# Get all open needs-maintainer-review issues
		local nmr_json
		nmr_json=$(gh_issue_list --repo "$slug" --label "needs-maintainer-review" \
			--state open --json number,author --limit 100 2>/dev/null) || nmr_json="[]"
		[[ -n "$nmr_json" && "$nmr_json" != "null" ]] || continue

		local nmr_count
		nmr_count=$(printf '%s' "$nmr_json" | jq 'length' 2>/dev/null) || nmr_count=0
		[[ "$nmr_count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$nmr_count" ]]; do
			local issue_num issue_author
			issue_num=$(printf '%s' "$nmr_json" | jq -r ".[$i].number" 2>/dev/null)
			issue_author=$(printf '%s' "$nmr_json" | jq -r ".[$i].author.login // empty" 2>/dev/null)
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			local should_approve=false
			local approval_reason=""
			_NMR_AUTO_APPROVAL_REASON_OVERRIDE=""

			# Case 1: maintainer created the issue — auto-approve unless NMR
			# was manually applied by the maintainer (intentional hold).
			if [[ "$issue_author" == "$maintainer" ]]; then
				if ! _nmr_current_actor_can_post_maintainer_approval "$issue_num" "$slug" "$maintainer" "$issue_author"; then
					echo "[pulse-wrapper] Skipping auto-approve for #${issue_num} in ${slug} — maintainer-authority trust-boundary check failed" >>"$LOGFILE"
				elif _nmr_applied_by_maintainer "$issue_num" "$slug" "$maintainer"; then
					echo "[pulse-wrapper] Skipping auto-approve for #${issue_num} in ${slug} — NMR manually applied by maintainer" >>"$LOGFILE"
				else
					should_approve=true
					approval_reason="${_NMR_AUTO_APPROVAL_REASON_OVERRIDE:-maintainer is author, NMR applied by automation}"
				fi
			fi

			# Case 2: cryptographic approval signature found
			if [[ "$should_approve" == "false" && -f "$approval_helper" ]]; then
				local verify_result
				verify_result=$(bash "$approval_helper" verify "$issue_num" "$slug" 2>/dev/null) || verify_result=""
				if [[ "$verify_result" == "VERIFIED" ]]; then
					should_approve=true
					approval_reason="cryptographic approval verified"
				fi
			fi

			if [[ "$should_approve" == "true" ]]; then
				# Lock the issue BEFORE posting the approval marker to prevent
				# comment prompt-injection. The marker (<!-- aidevops-signed-approval -->)
				# is trusted by maintainer-gate.yml — if an attacker could post a
				# comment containing it, they could bypass the NMR gate. Locking
				# ensures only collaborators can comment during the approval window.
				# The issue stays locked through dispatch (t1934) and unlocks after
				# the worker completes.
				gh issue lock "$issue_num" --repo "$slug" --reason "resolved" >/dev/null 2>&1 || true

				# Post the approval marker BEFORE removing the label.
				# maintainer-gate.yml checks for <!-- aidevops-signed-approval -->
				# when NMR is removed — if the marker is missing, it re-adds NMR.
				# Also resets the stale-recovery tick counter.
				gh_issue_comment "$issue_num" --repo "$slug" \
					--body "<!-- aidevops-signed-approval -->
<!-- stale-recovery-tick:0 (reset: auto-approved by maintainer — ${approval_reason}) -->
Auto-approved: ${approval_reason}. Stale recovery tick reset." \
					2>/dev/null || true

				_nmr_restore_dispatchable_state "$issue_num" "$slug"
				local edit_exit=$?
				if [[ "$edit_exit" -eq 0 ]]; then
					echo "[pulse-wrapper] Auto-approved #${issue_num} in ${slug} — ${approval_reason} (locked + approval marker + tick reset)" >>"$LOGFILE"
					total_approved=$((total_approved + 1))
					# t2845: promote knowledge-review source if this is a kind:knowledge-review issue
					_handle_knowledge_review_promotion "$issue_num" "$slug" || true
				else
					echo "[pulse-wrapper] Auto-approve label update FAILED for #${issue_num} in ${slug} (exit: ${edit_exit}) — approval marker posted but labels unchanged" >>"$LOGFILE"
				fi
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.maintainer // (.slug | split("/")[0]))"' "$repos_json" 2>/dev/null)

	if [[ "$total_approved" -gt 0 ]]; then
		echo "[pulse-wrapper] Auto-approve maintainer issues: approved ${total_approved} issue(s)" >>"$LOGFILE"
	fi

	return 0
}
