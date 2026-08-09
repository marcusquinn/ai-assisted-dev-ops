#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Stats Health Dashboard — Issue Lifecycle Sub-Library
# =============================================================================
# Functions for finding, creating, resolving, deduplicating, pinning, and
# unpinning health dashboard issues on GitHub.
#
# Usage: source "${SCRIPT_DIR}/stats-health-dashboard-issue.sh"
#
# Dependencies:
#   - shared-constants.sh (gh_issue_list, gh_issue_view, gh_create_issue, print_error, etc.)
#   - stats-shared.sh (_get_runner_role, _file_mtime_epoch)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_STATS_HEALTH_DASHBOARD_ISSUE_LOADED:-}" ]] && return 0
_STATS_HEALTH_DASHBOARD_ISSUE_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Shared constants — avoid repeated-string-literal lint findings across functions
_ROLE_SUPERVISOR="supervisor"
_ROLE_CONTRIBUTOR="contributor"
_HEALTH_PERSISTENT_LABEL="persistent"
_HEALTH_OPERATOR_LABEL_PREFIX="operator:"

# --- Functions ---

#######################################
# List open health issues matching a role + runner_user pair, filtered
# by title-prefix. Helper centralises the jq filter so `_find_health_issue`
# and `_periodic_health_issue_dedup` share one query definition.
#
# Arguments:
#   $1 - repo slug
#   $2 - role label (supervisor|contributor)
#   $3 - runner user
#   $4 - role display (Supervisor|Contributor)
# Output: JSON array sorted newest-first (by number desc).
# Returns: gh's exit code (non-zero on rate limit / network / API error).
#######################################
_list_health_issues_by_role_label() {
	local repo_slug="$1"
	local role_label="$2"
	local runner_user="$3"
	local role_display="$4"

	gh_issue_list --repo "$repo_slug" \
		--label "$role_label" --label "$runner_user" \
		--state open --json number,title \
		--jq "[.[] | select(.title | startswith(\"[${role_display}:\"))] | sort_by(.number) | reverse"
}

#######################################
# List open health issues that belong to one canonical dashboard identity.
# Matches the new canonical operator label, historical alias labels, and
# historical [Supervisor:alias]/[Contributor:alias] title prefixes. Existing
# operator:* labels are authoritative, so dashboards labelled for another
# canonical operator are excluded even when an old title prefix matches.
# Arguments:
#   $1 - repo slug
#   $2 - canonical identity
#   $3 - newline-delimited aliases
# Output: JSON array sorted newest-first (by number desc).
#######################################
_list_health_issues_by_canonical_identity() {
	local repo_slug="$1"
	local canonical_identity="$2"
	local identity_aliases="$3"

	local issues_json rc=0
	# Query the durable management label instead of source:health-dashboard so
	# pre-source-label dashboards are included in canonical identity dedup.
	issues_json=$(gh_issue_list --repo "$repo_slug" \
		--label "$_HEALTH_PERSISTENT_LABEL" \
		--state open --json number,title,labels --limit 500 2>/dev/null) || rc=$?
	if [[ $rc -ne 0 ]]; then
		return "$rc"
	fi

	local aliases_json
	aliases_json=$(printf '%s\n%s\n' "$canonical_identity" "$identity_aliases" | jq -R 'select(length > 0)' | jq -s 'unique')
	local canonical_label="${_HEALTH_OPERATOR_LABEL_PREFIX}${canonical_identity}"
	printf '%s' "${issues_json:-[]}" | jq \
		--argjson aliases "$aliases_json" \
		--arg canonical_label "$canonical_label" \
		'[
			.[]
			| . as $issue
			| ((.labels // []) | map(.name)) as $label_names
			| ($label_names | map(select(startswith("operator:")))) as $operator_labels
			| ($operator_labels | length == 0 or any(. == $canonical_label)) as $operator_label_allowed
			| ($label_names | any(. == $canonical_label or ($aliases | index(.)))) as $label_match
			| ((.title | capture("^\\[(Supervisor|Contributor):(?<user>[^]]+)\\]")? | .user // "") as $title_user
				| ($title_user != "" and ($aliases | index($title_user)))) as $title_match
			| select($operator_label_allowed and ($label_match or $title_match))
		] | sort_by(.number) | reverse'
	return 0
}

#######################################
# Converge dashboard labels and remove task lifecycle labels. Persistent health
# issues are observability surfaces, never dispatchable work items.
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - current runner user
#   $4 - current runner role
#   $5 - canonical operator identity
#######################################
_normalize_health_issue_labels() {
	local issue_number="$1"
	local repo_slug="$2"
	local runner_user="$3"
	local runner_role="$4"
	local canonical_identity="$5"

	local labels_json rc=0
	labels_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" --json labels 2>/dev/null) || rc=$?
	if [[ $rc -ne 0 || -z "$labels_json" ]]; then
		echo "[stats] Health issue: label normalization skipped for #${issue_number} in ${repo_slug} (rc=${rc})" \
			>>"${LOGFILE:-/dev/null}"
		return 0
	fi

	local label_names
	label_names=$(printf '%s' "$labels_json" | jq -r '(.labels // []) | map(.name) | .[]' 2>/dev/null) || return 0
	local expected_role_label="$_ROLE_CONTRIBUTOR"
	local opposite_role_label="$_ROLE_SUPERVISOR"
	if [[ "$runner_role" == "$_ROLE_SUPERVISOR" ]]; then
		expected_role_label="$_ROLE_SUPERVISOR"
		opposite_role_label="$_ROLE_CONTRIBUTOR"
	fi
	local canonical_label="${_HEALTH_OPERATOR_LABEL_PREFIX}${canonical_identity}"

	local -a edit_args=()
	local expected_label
	for expected_label in \
		"$_HEALTH_PERSISTENT_LABEL" "source:health-dashboard" "$expected_role_label" \
		"$runner_user" "$canonical_label" "origin:worker"; do
		if ! printf '%s\n' "$label_names" | grep -Fxq "$expected_label"; then
			edit_args+=(--add-label "$expected_label")
		fi
	done

	local stale_label
	while IFS= read -r stale_label; do
		[[ -n "$stale_label" ]] && edit_args+=(--remove-label "$stale_label")
	done < <(printf '%s\n' "$label_names" | jq -Rr \
		--arg opposite "$opposite_role_label" \
		'select(
			. == $opposite
			or . == "auto-dispatch"
			or . == "no-auto-dispatch"
			or . == "origin:interactive"
			or . == "origin:worker-takeover"
			or startswith("status:")
		)')

	[[ ${#edit_args[@]} -eq 0 ]] && return 0
	if ! gh_issue_edit_safe "$issue_number" --repo "$repo_slug" "${edit_args[@]}" >/dev/null 2>&1; then
		echo "[stats] Health issue: failed to normalize labels for #${issue_number} in ${repo_slug}" \
			>>"${LOGFILE:-/dev/null}"
	fi
	return 0
}

#######################################
# Return success when issue metadata has no operator label for another identity.
# Arguments:
#   $1 - issue JSON with labels
#   $2 - canonical identity
#######################################
_health_issue_operator_label_allows_identity() {
	local issue_json="$1"
	local canonical_identity="$2"
	local canonical_label="${_HEALTH_OPERATOR_LABEL_PREFIX}${canonical_identity}"
	local issue_json_input="${issue_json}"
	case "$issue_json_input" in
		""|[Oo][Pp][Ee][Nn]|[Cc][Ll][Oo][Ss][Ee][Dd]) issue_json_input='{}' ;;
	esac

	printf '%s' "$issue_json_input" | jq -e --arg canonical_label "$canonical_label" '
		((.labels // []) | map(.name) | map(select(startswith("operator:")))) as $operator_labels
		| ($operator_labels | length == 0 or any(. == $canonical_label))
	' >/dev/null 2>&1
	return $?
}

#######################################
# Validate a cached health-issue number: check it still exists, is OPEN, and
# is not labelled for a different canonical operator.
# Returns (via stdout):
#   - the cached number if still valid
#   - empty if the cache entry points to a CLOSED issue (caller should re-resolve)
#   - $_HEALTH_QUERY_FAILED_SENTINEL if `gh issue view` failed (rate-limit/network)
# Side effects: removes the cache file on CLOSED state, unpins on CLOSED supervisor.
#######################################
_try_cached_health_issue_lookup() {
	local health_issue_file="$1"
	local repo_slug="$2"
	local runner_role="$3"
	local canonical_identity="${4:-}"

	[[ ! -f "$health_issue_file" ]] && return 0  # empty stdout

	local cached_number
	cached_number=$(<"$health_issue_file") || cached_number=""
	[[ -z "$cached_number" ]] && return 0
	if ! _health_issue_number_is_valid "$cached_number"; then
		echo "[stats] Health issue: ignoring corrupt cached issue number in ${health_issue_file}" >>"${LOGFILE:-/dev/null}"
		rm -f "$health_issue_file" 2>/dev/null || true
		return 0
	fi

	local issue_json issue_state rc=0
	issue_json=$(gh_issue_view "$cached_number" --repo "$repo_slug" --json state,labels 2>/dev/null) || rc=$?

	if [[ $rc -ne 0 ]]; then
		# Query failed (rate limit, network, API 5xx). Preserve cache and return
		# it — caller still points to a valid-as-far-as-we-know issue.
		echo "[stats] Health issue: cache validation failed for #${cached_number} in ${repo_slug} (rc=${rc}) — preserving cache" >>"${LOGFILE:-/dev/null}"
		echo "$cached_number"
		return 0
	fi

	local raw_issue_json="$issue_json"
	case "$raw_issue_json" in
		""|[Oo][Pp][Ee][Nn]|[Cc][Ll][Oo][Ss][Ee][Dd])
			issue_state="$raw_issue_json"
			issue_json='{}'
			;;
		*)
			issue_state=$(printf '%s' "$issue_json" | jq -r '.state // empty' || echo "")
			;;
	esac

	# gh issue view has returned both GraphQL-style uppercase enums (OPEN/CLOSED)
	# and REST-style lowercase values (open/closed) depending on fallback path.
	# Normalize before branching so REST fallback cache validation does not log
	# healthy open dashboards as "unexpected state" every stats-wrapper cycle.
	local closed_state="CLOSED"
	local open_state="OPEN"
	case "$issue_state" in
		[Oo][Pp][Ee][Nn]) issue_state="$open_state" ;;
		[Cc][Ll][Oo][Ss][Ee][Dd]) issue_state="$closed_state" ;;
	esac

	if [[ "$issue_state" == "$closed_state" ]]; then
		[[ "$runner_role" == "$_ROLE_SUPERVISOR" ]] && _unpin_health_issue "$cached_number" "$repo_slug"
		rm -f "$health_issue_file" 2>/dev/null || true
		return 0  # empty → caller re-resolves
	fi

	if [[ "$issue_state" != "$open_state" ]]; then
		# Unexpected state (empty, unknown enum). Preserve cache defensively.
		echo "[stats] Health issue: unexpected state '${issue_state}' for #${cached_number} in ${repo_slug} — preserving cache" >>"${LOGFILE:-/dev/null}"
		echo "$cached_number"
		return 0
	fi

	if [[ -n "$canonical_identity" ]] && ! _health_issue_operator_label_allows_identity "$issue_json" "$canonical_identity"; then
		echo "[stats] Health issue: ignoring cached issue #${cached_number} for ${canonical_identity} in ${repo_slug} because it has a conflicting operator label" >>"${LOGFILE:-/dev/null}"
		rm -f "$health_issue_file" 2>/dev/null || true
		return 0
	fi

	echo "$cached_number"
	return 0
}

#######################################
# Validate a health-dashboard issue number before using it as the canonical
# supersession target for persistent issue dedup closes.
# Arguments:
#   $1 - candidate issue number
#######################################
_health_issue_number_is_valid() {
	local issue_number="$1"
	[[ "$issue_number" =~ ^[0-9]+$ ]]
	return $?
}

#######################################
# Extract one issue number from wrapper/gh output. Some wrapper paths can emit
# more than the created issue URL/number; callers must never persist or use a
# multi-line value as a supersession target.
# Arguments:
#   $1 - raw command output
#######################################
_health_issue_number_from_text() {
	local raw_output="$1"
	printf '%s\n' "$raw_output" | awk 'match($0, /[0-9]+$/) { value=substr($0, RSTART, RLENGTH) } END { if (value != "") print value }'
	return 0
}

#######################################
# Strip the 'persistent' label from a health issue before closing it,
# preventing issue-sync.yml 'Reopen Persistent Issues' from reopening
# programmatic dedup closes (GH#20326). Idempotent: no-op if not present.
# Arguments:
#   $1 - issue number
#   $2 - repo slug
_strip_persistent_label_before_close() {
	local issue_number="$1"
	local repo_slug="$2"
	gh issue edit "$issue_number" --repo "$repo_slug" --remove-label persistent 2>/dev/null || true
	return 0
}

#######################################
# Close all duplicate health issues (all but the first) from a jq array.
# Arguments: label_results_json keep_number repo_slug runner_role
_close_health_issue_duplicates() {
	local label_results="$1" keep_number="$2" repo_slug="$3" runner_role="$4"
	if ! _health_issue_number_is_valid "$keep_number"; then
		echo "[stats] Health issue: refusing duplicate close without a single numeric supersession target: ${keep_number}" >>"${LOGFILE:-/dev/null}"
		return 0
	fi

	local dup_count
	dup_count=$(printf '%s' "$label_results" | jq 'length' 2>/dev/null || echo "0")
	[[ "${dup_count:-0}" -le 1 ]] && return 0

	local dup_numbers
	dup_numbers=$(printf '%s' "$label_results" | jq -r '.[1:][].number' 2>/dev/null || echo "")
	while IFS= read -r dup_num; do
		[[ -z "$dup_num" ]] && continue
		_health_issue_number_is_valid "$dup_num" || continue
		[[ "$runner_role" == "$_ROLE_SUPERVISOR" ]] && _unpin_health_issue "$dup_num" "$repo_slug"
		_strip_persistent_label_before_close "$dup_num" "$repo_slug"
		gh issue close "$dup_num" --repo "$repo_slug" \
			--comment "Closing duplicate ${runner_role} health issue — superseded by #${keep_number}." 2>/dev/null || true
	done <<<"$dup_numbers"
	return 0
}

#######################################
# Close duplicate health issues across aliases and role prefixes.
# Arguments: results_json keep_number repo_slug canonical_identity runner_user
#######################################
_close_health_issue_identity_duplicates() {
	local identity_results="$1"
	local keep_number="$2"
	local repo_slug="$3"
	local canonical_identity="$4"
	local runner_user="$5"
	if ! _health_issue_number_is_valid "$keep_number"; then
		echo "[stats] Health issue: refusing identity duplicate close without a single numeric supersession target: ${keep_number}" >>"${LOGFILE:-/dev/null}"
		return 0
	fi

	local dup_count
	dup_count=$(printf '%s' "$identity_results" | jq 'length' 2>/dev/null || echo "0")
	[[ "${dup_count:-0}" -le 1 ]] && return 0

	local dup_numbers
	dup_numbers=$(printf '%s' "$identity_results" | jq -r --arg keep "$keep_number" \
		'.[] | select((.number | tostring) != $keep) | .number' 2>/dev/null || echo "")
	while IFS= read -r dup_num; do
		[[ -z "$dup_num" ]] && continue
		_health_issue_number_is_valid "$dup_num" || continue
		_unpin_health_issue "$dup_num" "$repo_slug"
		_strip_persistent_label_before_close "$dup_num" "$repo_slug"
		gh issue close "$dup_num" --repo "$repo_slug" \
			--comment "Closing duplicate health dashboard for canonical operator ${canonical_identity} (current runner ${runner_user}) — superseded by #${keep_number}. Identity aliases map this dashboard to the same operator across local/GitHub usernames and role prefixes." 2>/dev/null || true
	done <<<"$dup_numbers"
	return 0
}

#######################################
# Title-based fallback lookup with label backfill. Preserves migration for
# legacy dashboards without operator:* labels, but refuses dashboards already
# labelled for another canonical operator.
# Returns issue number if found, empty if not, $_HEALTH_QUERY_FAILED_SENTINEL on failure.
_try_title_health_issue_fallback() {
	local runner_prefix="$1" repo_slug="$2" runner_user="$3" role_label="$4" role_display="$5"
	local canonical_identity="${6:-$runner_user}"
	local canonical_label="${_HEALTH_OPERATOR_LABEL_PREFIX}${canonical_identity}"

	local title_result rc=0
	title_result=$(gh_issue_list --repo "$repo_slug" \
		--search "in:title ${runner_prefix}" \
		--state open --json number,title,labels \
		--jq "[.[] | select(.title | startswith(\"${runner_prefix}\")) | select(((.labels // []) | map(.name) | map(select(startswith(\"operator:\")))) as \$operator_labels | (\$operator_labels | length == 0 or any(. == \"${canonical_label}\")))][0].number" 2>/dev/null) || rc=$?

	if [[ $rc -ne 0 ]]; then
		echo "[stats] Health issue: title lookup failed for ${runner_prefix} in ${repo_slug} (rc=${rc}) — abstaining this cycle" >>"${LOGFILE:-/dev/null}"
		echo "$_HEALTH_QUERY_FAILED_SENTINEL"
		return 0
	fi

	local health_issue_number
	health_issue_number=$(_health_issue_number_from_text "${title_result:-}")
	if [[ -n "$health_issue_number" ]]; then
		gh label create "$runner_user" --repo "$repo_slug" --color "0E8A16" \
			--description "${role_display} runner: ${runner_user}" --force 2>/dev/null || true
		gh issue edit "$health_issue_number" --repo "$repo_slug" \
			--add-label "$role_label" --add-label "$runner_user" 2>/dev/null || true
	fi
	echo "$health_issue_number"
	return 0
}

_find_health_issue() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local runner_prefix="$4"
	local role_label="$5"
	local role_display="$6"
	local health_issue_file="$7"
	local canonical_identity="${8:-$runner_user}"
	local identity_aliases="${9:-$runner_user}"

	local health_issue_number
	health_issue_number=$(_try_cached_health_issue_lookup \
		"$health_issue_file" "$repo_slug" "$runner_role" "$canonical_identity")

	# Sentinel from cache lookup is defensive only; current behaviour preserves
	# the cached number on error, but downstream checks still need it to pass
	# through. Short-circuit on sentinel.
	if [[ "$health_issue_number" == "$_HEALTH_QUERY_FAILED_SENTINEL" ]]; then
		echo "$_HEALTH_QUERY_FAILED_SENTINEL"
		return 0
	fi

	# Search by canonical identity across aliases/roles if cache gave nothing.
	if [[ -z "$health_issue_number" ]]; then
		local identity_results identity_rc=0
		identity_results=$(_list_health_issues_by_canonical_identity \
			"$repo_slug" "$canonical_identity" "$identity_aliases" 2>/dev/null) || identity_rc=$?
		if [[ $identity_rc -ne 0 ]]; then
			echo "[stats] Health issue: identity lookup failed for ${canonical_identity} in ${repo_slug} (rc=${identity_rc}) — abstaining this cycle" >>"${LOGFILE:-/dev/null}"
			echo "$_HEALTH_QUERY_FAILED_SENTINEL"
			return 0
		fi
		identity_results="${identity_results:-[]}"
		health_issue_number=$(printf '%s' "$identity_results" | jq -r '.[0].number // empty' 2>/dev/null || echo "")
		_close_health_issue_identity_duplicates "$identity_results" "$health_issue_number" "$repo_slug" "$canonical_identity" "$runner_user"
	fi

	# Legacy role+runner label search if canonical identity found nothing.
	if [[ -z "$health_issue_number" ]]; then
		local label_results rc=0
		label_results=$(_list_health_issues_by_role_label \
			"$repo_slug" "$role_label" "$runner_user" "$role_display" 2>/dev/null) || rc=$?

		if [[ $rc -ne 0 ]]; then
			# Abstain this cycle. Emit sentinel so _resolve_health_issue_number
			# refuses to create a duplicate.
			echo "[stats] Health issue: label lookup failed for ${role_label}+${runner_user} in ${repo_slug} (rc=${rc}) — abstaining this cycle" >>"${LOGFILE:-/dev/null}"
			echo "$_HEALTH_QUERY_FAILED_SENTINEL"
			return 0
		fi

		label_results="${label_results:-[]}"
		health_issue_number=$(printf '%s' "$label_results" | jq -r '.[0].number // empty' 2>/dev/null || echo "")
		_close_health_issue_duplicates "$label_results" "$health_issue_number" "$repo_slug" "$runner_role"
	fi

	# Fallback: title-based search with label backfill.
	if [[ -z "$health_issue_number" ]]; then
		health_issue_number=$(_try_title_health_issue_fallback \
			"$runner_prefix" "$repo_slug" "$runner_user" "$role_label" "$role_display" \
			"$canonical_identity")
	fi

	echo "$health_issue_number"
	return 0
}

#######################################
# Create a new health issue for a runner+repo and optionally pin it.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user
#   $3 - runner role (supervisor|contributor)
#   $4 - runner prefix (e.g. "[Supervisor:user]")
#   $5 - role label (supervisor|contributor)
#   $6 - role label color
#   $7 - role label desc
#   $8 - role display (Supervisor|Contributor)
# Output: new issue number to stdout (empty on failure)
#######################################
_create_health_issue() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local runner_prefix="$4"
	local role_label="$5"
	local role_label_color="$6"
	local role_label_desc="$7"
	local role_display="$8"
	local canonical_identity="${9:-$runner_user}"
	local identity_aliases="${10:-$runner_user}"
	local runner_label_color="0E8A16"
	local operator_label="${_HEALTH_OPERATOR_LABEL_PREFIX}${canonical_identity}"

	gh label create "$role_label" --repo "$repo_slug" --color "$role_label_color" \
		--description "$role_label_desc" --force 2>/dev/null || true
	gh label create "$runner_user" --repo "$repo_slug" --color "$runner_label_color" \
		--description "${role_display} runner: ${runner_user}" --force 2>/dev/null || true
	gh label create "$operator_label" --repo "$repo_slug" --color "$runner_label_color" \
		--description "Canonical dashboard operator: ${canonical_identity}" --force 2>/dev/null || true
	gh label create "source:health-dashboard" --repo "$repo_slug" --color "C2E0C6" \
		--description "Auto-created by stats-functions.sh health dashboard" --force 2>/dev/null || true
	# t1890: health dashboard issues are management issues that should never be
	# closed or dispatched. Add the "persistent" label for consistency with the
	# quality review issue, so the dispatch filter only needs one label check.
	gh label create "$_HEALTH_PERSISTENT_LABEL" --repo "$repo_slug" --color "FBCA04" \
		--description "Persistent issue — do not close" --force 2>/dev/null || true

	local aliases_csv
	aliases_csv=$(printf '%s\n' "$identity_aliases" | paste -sd ', ' -)
	local health_body="Live ${runner_role} status for **${runner_user}**. Canonical operator: **${canonical_identity}**. Identity aliases: ${aliases_csv}. Updated each pulse. Pin this issue for at-a-glance monitoring."
	local sig_footer=""
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$health_body" 2>/dev/null || true)
	health_body="${health_body}${sig_footer}"

	# t2691/GH#20311: Health dashboard issues are always created by the
	# headless pulse context. Force AIDEVOPS_SESSION_ORIGIN=worker so
	# gh_create_issue applies origin:worker regardless of whether the
	# caller has AIDEVOPS_HEADLESS set (defense-in-depth; stats-wrapper.sh
	# already exports AIDEVOPS_HEADLESS=true, but this guards test contexts
	# and any future invocation path that bypasses that wrapper).
	local health_issue_number
	health_issue_number=$(AIDEVOPS_SESSION_ORIGIN=worker gh_create_issue --repo "$repo_slug" \
		--title "${runner_prefix} starting..." \
		--body "$health_body" \
		--label "$role_label" --label "$runner_user" --label "$operator_label" --label "source:health-dashboard" --label "$_HEALTH_PERSISTENT_LABEL" 2>/dev/null || echo "")
	health_issue_number=$(_health_issue_number_from_text "$health_issue_number")

	if [[ -z "$health_issue_number" ]]; then
		echo "[stats] Health issue: could not create for ${repo_slug}" >>"$LOGFILE"
		echo ""
		return 0
	fi

	# Pin only supervisor issues — contributor issues don't pin because
	# GitHub allows max 3 pinned issues per repo and those slots are
	# reserved for maintainer dashboards and the quality review issue.
	if [[ "$runner_role" == "$_ROLE_SUPERVISOR" ]]; then
		local node_id
		node_id=$(gh_issue_view "$health_issue_number" --repo "$repo_slug" --json id --jq '.id' 2>/dev/null || echo "")
		if [[ -n "$node_id" ]]; then
			gh api graphql -f query="
				mutation {
					pinIssue(input: {issueId: \"${node_id}\"}) {
						issue { number }
					}
				}" >/dev/null 2>&1 || true
		fi
	fi
	echo "[stats] Health issue: created #${health_issue_number} (${runner_role}) for ${runner_user} in ${repo_slug}" >>"$LOGFILE"

	echo "$health_issue_number"
	return 0
}

#######################################
# Resolve (find or create) the health issue number for a runner+repo.
#
# Delegates to _find_health_issue then _create_health_issue if not found.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user
#   $3 - runner role (supervisor|contributor)
#   $4 - runner prefix (e.g. "[Supervisor:user]")
#   $5 - role label (supervisor|contributor)
#   $6 - role label color
#   $7 - role label desc
#   $8 - role display (Supervisor|Contributor)
#   $9 - cache file path
# Output: issue number to stdout (empty on failure)
#######################################
_resolve_health_issue_number() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local runner_prefix="$4"
	local role_label="$5"
	local role_label_color="$6"
	local role_label_desc="$7"
	local role_display="$8"
	local health_issue_file="$9"
	local canonical_identity="${10:-$runner_user}"
	local identity_aliases="${11:-$runner_user}"

	local health_issue_number
	health_issue_number=$(_find_health_issue \
		"$repo_slug" "$runner_user" "$runner_role" "$runner_prefix" \
		"$role_label" "$role_display" "$health_issue_file" \
		"$canonical_identity" "$identity_aliases")

	# t2687: honour the query-failed sentinel from _find_health_issue.
	# When the API was unreachable for the dedup lookups, abstain from
	# creation this cycle — otherwise we create duplicates every time
	# GraphQL is exhausted (the root cause of GH#20301).
	if [[ "$health_issue_number" == "$_HEALTH_QUERY_FAILED_SENTINEL" ]]; then
		echo "[stats] Health issue: abstaining from create/update cycle for ${repo_slug} (runner=${runner_user}, role=${runner_role}) — dedup lookups failed" >>"${LOGFILE:-/dev/null}"
		echo ""
		return 0
	fi

	if [[ -z "$health_issue_number" ]]; then
		health_issue_number=$(_create_health_issue \
			"$repo_slug" "$runner_user" "$runner_role" "$runner_prefix" \
			"$role_label" "$role_label_color" "$role_label_desc" "$role_display" \
			"$canonical_identity" "$identity_aliases")
	fi

	echo "$health_issue_number"
	return 0
}

#######################################
# Periodic label-based dedup scan (t2687, GH#20301).
#
# Even when the cached health issue is valid and returns quickly via
# _find_health_issue, the label-based dedup block inside that function
# is bypassed because the cache-hit path short-circuits before the
# label scan runs. That means duplicates that slipped in during past
# GraphQL rate-limit windows never get closed automatically — they
# require either a cache invalidation or manual intervention.
#
# This helper runs the same label-based dedup at most once per hour
# per repo-runner-role tuple, keyed by a timestamp state file. On
# query failure (rc != 0), the state file is NOT updated so the next
# pulse cycle retries — avoids starving the scan during an extended
# rate-limit window.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user
#   $3 - runner role (supervisor|contributor)
#   $4 - role label (supervisor|contributor)
#   $5 - role display (Supervisor|Contributor)
#   $6 - current (kept) health issue number
# Env:
#   HEALTH_DEDUP_INTERVAL - seconds between scans per (repo, runner, role).
#                           Default 3600 (1 hour).
# Returns: 0 always (best-effort, never breaks the pulse).
#######################################
_periodic_health_issue_dedup() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local role_label="$4"
	local role_display="$5"
	local current_issue="$6"
	local use_identity_dedup=0
	[[ $# -ge 7 ]] && use_identity_dedup=1
	local canonical_identity="${7:-$runner_user}"
	local identity_aliases="${8:-$runner_user}"

	[[ -z "$repo_slug" || -z "$runner_user" || -z "$role_label" || -z "$current_issue" ]] && return 0
	if ! _health_issue_number_is_valid "$current_issue"; then
		echo "[stats] Health issue: periodic dedup skipped for ${repo_slug}; invalid current issue '${current_issue}'" >>"${LOGFILE:-/dev/null}"
		return 0
	fi

	local slug_safe="${repo_slug//\//-}"
	local cache_dir="${HOME}/.aidevops/logs"
	local state_file="${cache_dir}/health-dedup-last-scan-${canonical_identity}-${slug_safe}"
	if [[ $use_identity_dedup -eq 0 ]]; then
		state_file="${cache_dir}/health-dedup-last-scan-${runner_user}-${role_label}-${slug_safe}"
	fi
	local interval="${HEALTH_DEDUP_INTERVAL:-3600}"

	# Throttle: skip if last scan was recent
	if [[ -f "$state_file" ]]; then
		local last_scan_epoch now_epoch elapsed
		last_scan_epoch=$(_file_mtime_epoch "$state_file")
		now_epoch=$(date +%s)
		elapsed=$((now_epoch - last_scan_epoch))
		if [[ $elapsed -lt $interval ]]; then
			return 0
		fi
	fi

	mkdir -p "$cache_dir" 2>/dev/null || true

	local label_results rc=0
	if [[ $use_identity_dedup -eq 1 ]]; then
		label_results=$(_list_health_issues_by_canonical_identity \
			"$repo_slug" "$canonical_identity" "$identity_aliases" 2>/dev/null) || rc=$?
	else
		label_results=$(_list_health_issues_by_role_label \
			"$repo_slug" "$role_label" "$runner_user" "$role_display" 2>/dev/null) || rc=$?
	fi

	if [[ $rc -ne 0 ]]; then
		# Leave state_file alone — retry next pulse cycle.
		echo "[stats] Health issue: periodic dedup scan failed for ${repo_slug} (rc=${rc}) — will retry next cycle" >>"${LOGFILE:-/dev/null}"
		return 0
	fi

	label_results="${label_results:-[]}"

	local total_count
	total_count=$(printf '%s' "$label_results" | jq 'length' 2>/dev/null || echo "0")

	if [[ "${total_count:-0}" -gt 1 ]]; then
		local dup_numbers
		# Close every issue in the identity-match set except the one we're
		# currently using. The cached/resolved issue is the canonical one
		# because its body+title are up-to-date with this pulse.
		dup_numbers=$(printf '%s' "$label_results" | jq -r --arg keep "$current_issue" \
			'.[] | select((.number | tostring) != $keep) | .number' 2>/dev/null || echo "")
		while IFS= read -r dup_num; do
			[[ -z "$dup_num" ]] && continue
			_health_issue_number_is_valid "$dup_num" || continue
			# _unpin_health_issue is already best-effort and a no-op for
			# unpinned (contributor) issues, so call unconditionally.
			# Duplicate supervisor issues CAN be pinned in pathological
			# cases (stale pin from a pre-rate-limit canonical).
			_unpin_health_issue "$dup_num" "$repo_slug"
			_strip_persistent_label_before_close "$dup_num" "$repo_slug"
			gh issue close "$dup_num" --repo "$repo_slug" \
				--comment "Closing duplicate health dashboard for canonical operator ${canonical_identity} — superseded by #${current_issue} (alias/role periodic dedup for current runner ${runner_user})." 2>/dev/null || true
			echo "[stats] Health issue: periodic dedup closed #${dup_num} in ${repo_slug} (kept #${current_issue})" >>"${LOGFILE:-/dev/null}"
		done <<<"$dup_numbers"
	fi

	# Update state file timestamp (even when no duplicates found) so we
	# don't re-query every cycle.
	touch "$state_file" 2>/dev/null || true

	return 0
}

#######################################
# Resolve role-specific config variables for a runner.
#
# Outputs pipe-delimited fields:
#   runner_prefix|role_label|role_label_color|role_label_desc|role_display
#
# Arguments:
#   $1 - runner_user
#   $2 - runner_role (supervisor|contributor)
#######################################
_resolve_runner_role_config() {
	local runner_user="$1"
	local runner_role="$2"

	local runner_prefix role_label role_label_color role_label_desc role_display
	if [[ "$runner_role" == "$_ROLE_SUPERVISOR" ]]; then
		runner_prefix="[Supervisor:${runner_user}]"
		role_label="$_ROLE_SUPERVISOR"
		role_label_color="1D76DB"
		role_label_desc="Supervisor health dashboard"
		role_display="Supervisor"
	else
		runner_prefix="[Contributor:${runner_user}]"
		role_label="$_ROLE_CONTRIBUTOR"
		role_label_color="A2EEEF"
		role_label_desc="Contributor health dashboard"
		role_display="Contributor"
	fi

	printf '%s|%s|%s|%s|%s' \
		"$runner_prefix" "$role_label" "$role_label_color" \
		"$role_label_desc" "$role_display"
	return 0
}

#######################################
# Ensure the active health issue is pinned (supervisor-only).
#
# Unpins closed/stale issues to free pin slots (max 3 per repo),
# then pins the active issue idempotently.
#
# Arguments:
#   $1 - health_issue_number
#   $2 - repo_slug
#   $3 - runner_user (for _cleanup_stale_pinned_issues)
#######################################
_ensure_health_issue_pinned() {
	local health_issue_number="$1"
	local repo_slug="$2"
	local runner_user="$3"

	_cleanup_stale_pinned_issues "$repo_slug" "$runner_user"

	local active_node_id
	active_node_id=$(gh_issue_view "$health_issue_number" --repo "$repo_slug" \
		--json id --jq '.id' 2>/dev/null || echo "")
	if [[ -n "$active_node_id" ]]; then
		gh api graphql -f query="
			mutation {
				pinIssue(input: {issueId: \"${active_node_id}\"}) {
					issue { number }
				}
			}" >/dev/null 2>&1 || true
	fi
	return 0
}

#######################################
# Unpin closed/stale supervisor issues to free pin slots
#
# GitHub allows max 3 pinned issues per repo. Old supervisor issues
# that were closed (manually or by dedup) may still be pinned, blocking
# the active health issue from being pinned. This function finds all
# pinned issues in the repo and unpins any that are closed.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user (for logging)
#######################################
_cleanup_stale_pinned_issues() {
	local repo_slug="$1"
	local runner_user="$2"
	local owner="${repo_slug%%/*}"
	local name="${repo_slug##*/}"

	# Query all pinned issues via GraphQL (parameterized to prevent injection)
	local pinned_json
	pinned_json=$(gh api graphql -F owner="$owner" -F name="$name" -f query="
		query(\$owner: String!, \$name: String!) {
			repository(owner: \$owner, name: \$name) {
				pinnedIssues(first: 10) {
					nodes {
						issue {
							id
							number
							state
							title
						}
					}
				}
			}
		}
		" 2>>"$LOGFILE" || echo "")

	[[ -z "$pinned_json" ]] && return 0

	# Unpin any closed issues
	local closed_pinned
	closed_pinned=$(echo "$pinned_json" | jq -r '.data.repository.pinnedIssues.nodes[] | select(.issue.state == "CLOSED") | "\(.issue.id)|\(.issue.number)"' 2>/dev/null || echo "")

	[[ -z "$closed_pinned" ]] && return 0

	while IFS='|' read -r node_id issue_num; do
		[[ -z "$node_id" ]] && continue
		gh api graphql -f query="
			mutation {
				unpinIssue(input: {issueId: \"${node_id}\"}) {
					issue { number }
				}
			}" >/dev/null 2>&1 || true
		echo "[stats] Health issue: unpinned closed issue #${issue_num} in ${repo_slug}" >>"$LOGFILE"
	done <<<"$closed_pinned"

	return 0
}

#######################################
# Unpin a health issue (best-effort)
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#######################################
_unpin_health_issue() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ -z "$issue_number" || -z "$repo_slug" ]] && return 0

	local issue_node_id
	issue_node_id=$(gh_issue_view "$issue_number" --repo "$repo_slug" --json id --jq '.id' 2>/dev/null || echo "")
	[[ -z "$issue_node_id" ]] && return 0

	gh api graphql -f query="
		mutation {
			unpinIssue(input: {issueId: \"${issue_node_id}\"}) {
				issue { number }
			}
		}" >/dev/null 2>&1 || true

	return 0
}
