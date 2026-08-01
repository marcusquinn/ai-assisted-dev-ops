#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# gh-audit-log-helper.sh — Structured audit log for destructive GitHub operations (GH#20145)
# Commands: record | status | rotate | help
# Docs: reference/gh-audit-log.md
#
# Writes one NDJSON event per invocation to ~/.aidevops/logs/gh-audit.log.
# Called by gh_issue_edit_safe, gh_issue_close_safe, gh_issue_reopen_safe,
# gh_pr_edit_safe, gh_pr_close_safe, and gh_pr_merge_safe wrappers.
#
# Event schema (all fields JSON-typed):
#   ts              — ISO 8601 UTC timestamp
#   op              — issue_edit | issue_close | issue_reopen |
#                     pr_edit | pr_close | pr_merge
#   repo            — "owner/repo"
#   number          — issue or PR number (integer)
#   caller_script   — basename of the script that invoked the wrapper
#   caller_function — function name in the calling stack
#   caller_line     — line number in caller_script
#   pid             — process ID of the caller
#   flags           — object of relevant env vars (FORCE_ENRICH, etc.)
#   before          — {capture_status:"ok|unavailable", title_len:N|null,
#                      body_len:N|null, labels:["l1","l2"]|null}
#   after           — same shape as before
#   delta           — {comparable:true|false, title_delta_pct:N|null,
#                      body_delta_pct:N|null,
#                      labels_removed:[], labels_added:[]}
#   suspicious      — array of anomaly signal strings (empty = normal)
#
# Usage:
#   gh-audit-log-helper.sh record \
#     --op issue_edit --repo owner/repo --number 123 \
#     [--before-json '{"title_len":87,"body_len":4000,"labels":["l1"]}'] \
#     [--after-json  '{"title_len":10,"body_len":0,   "labels":["l2"]}'] \
#     [--caller-script NAME] [--caller-function FUNC] [--caller-line N]
#   gh-audit-log-helper.sh status
#   gh-audit-log-helper.sh rotate [--max-size MB]
#   gh-audit-log-helper.sh help
#
# Environment:
#   GH_AUDIT_LOG_FILE       Override log file path
#   GH_AUDIT_QUIET          Suppress stderr info when "true"
#   GH_AUDIT_MAX_SIZE_MB    Rotation threshold in MB (default: 10)
#   GH_AUDIT_MAX_ROTATIONS  Max rotations to keep (default: 10)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" || true
init_log_file || true

# =============================================================================
# Constants
# =============================================================================

readonly GH_AUDIT_VERSION="1.1.0"
readonly GH_AUDIT_LOG_DIR_DEFAULT="${HOME}/.aidevops/logs"
readonly GH_AUDIT_LOG_FILENAME="gh-audit.log"
readonly GH_AUDIT_MAX_SIZE_MB_DEFAULT=10
readonly GH_AUDIT_MAX_ROTATIONS_DEFAULT=10
readonly GH_AUDIT_CAPTURE_OK="ok"
readonly GH_AUDIT_CAPTURE_UNAVAILABLE="unavailable"
readonly GH_AUDIT_UNAVAILABLE_STATE_JSON='{"capture_status":"unavailable","title_len":null,"body_len":null,"labels":null}'

# Anomaly thresholds
readonly GH_AUDIT_TITLE_SHRINK_PCT_THRESHOLD=50 # flag if title shrinks >50%
readonly GH_AUDIT_BODY_WIPE_THRESHOLD=100       # flag if body goes to 0

# Labels whose removal is always suspicious
readonly GH_AUDIT_PROTECTED_LABELS=(
	"status:in-review"
	"status:in-progress"
	"status:claimed"
	"origin:interactive"
	"no-auto-dispatch"
	"needs-maintainer-review"
	"needs-maintainer-permissions"
)

# Valid operation names
readonly GH_AUDIT_VALID_OPS=(
	"issue_edit"
	"issue_close"
	"issue_reopen"
	"pr_edit"
	"pr_close"
	"pr_merge"
)

# =============================================================================
# Internal helpers
# =============================================================================

# Resolve the audit log file path.
_gh_audit_log_path() {
	local dir="${GH_AUDIT_LOG_DIR:-${GH_AUDIT_LOG_DIR_DEFAULT}}"
	local file="${GH_AUDIT_LOG_FILE:-${dir}/${GH_AUDIT_LOG_FILENAME}}"
	echo "$file"
	return 0
}

# Count bytes in a file (portable, trims whitespace).
_gh_audit_byte_count() {
	local _f="$1"
	wc -c <"$_f" | tr -d ' '
	return 0
}

# Count lines in a file (portable, trims whitespace).
_gh_audit_line_count() {
	local _f="$1"
	wc -l <"$_f" | tr -d ' '
	return 0
}

# Ensure the log directory and file exist with appropriate permissions.
_gh_audit_ensure_log() {
	local log_file
	log_file="$(_gh_audit_log_path)"
	local log_dir
	log_dir="$(dirname "$log_file")"

	if [[ ! -d "$log_dir" ]]; then
		mkdir -p "$log_dir" || true
		chmod 700 "$log_dir" || true
	fi

	if [[ ! -f "$log_file" ]]; then
		: >"$log_file"
		chmod 600 "$log_file" || true
	fi

	return 0
}

# Print info to stderr (suppressed when GH_AUDIT_QUIET=true).
_gh_audit_info() {
	local msg="$1"
	if [[ "${GH_AUDIT_QUIET:-false}" != "true" ]]; then
		printf '%b[GH-AUDIT]%b %s\n' "${GREEN:-}" "${NC:-}" "$msg" >&2
	fi
	return 0
}

# Print warning to stderr.
_gh_audit_warn() {
	local msg="$1"
	printf '%b[GH-AUDIT WARN]%b %s\n' "${YELLOW:-}" "${NC:-}" "$msg" >&2
	return 0
}

# Escape a string for JSON embedding.
# Uses jq when available; plain sed fallback for minimal envs.
_gh_audit_json_escape() {
	local input="$1"
	if command -v jq &>/dev/null; then
		printf '%s' "$input" | jq -Rs '.' | sed 's/^"//;s/"$//'
		return 0
	fi
	local escaped="$input"
	escaped="${escaped//\\/\\\\}"
	escaped="${escaped//\"/\\\"}"
	escaped="${escaped//$'\n'/\\n}"
	escaped="${escaped//$'\t'/\\t}"
	escaped="${escaped//$'\r'/\\r}"
	escaped="$(printf '%s' "$escaped" | tr -d '\000-\010\013\014\016-\037')"
	echo "$escaped"
	return 0
}

# Build a JSON array from a comma-separated label string.
# Input: "l1,l2,l3"  Output: ["l1","l2","l3"]
_gh_audit_labels_to_json_array() {
	local labels_csv="$1"
	if [[ -z "$labels_csv" ]]; then
		echo "[]"
		return 0
	fi
	if command -v jq &>/dev/null; then
		printf '%s' "$labels_csv" | jq -Rc 'split(",")'
		return 0
	fi
	# Fallback: manual construction
	local result='['
	local first=1
	local label
	# Read comma-separated into array (Bash 3.2 compatible)
	local IFS_ORIG="$IFS"
	IFS=','
	for label in $labels_csv; do
		IFS="$IFS_ORIG"
		local escaped
		escaped="$(_gh_audit_json_escape "$label")"
		if [[ "$first" -eq 1 ]]; then
			result="${result}\"${escaped}\""
			first=0
		else
			result="${result},\"${escaped}\""
		fi
		IFS=','
	done
	IFS="$IFS_ORIG"
	result="${result}]"
	echo "$result"
	return 0
}

# Compute integer absolute value.
_gh_audit_abs() {
	local n="$1"
	if [[ "$n" -lt 0 ]]; then
		echo $((-n))
	else
		echo "$n"
	fi
	return 0
}

# Compute delta percentage: ((after - before) * 100) / before
# Returns 0 if before is 0 (no-op baseline).
_gh_audit_delta_pct() {
	local before="$1"
	local after="$2"
	if [[ "$before" -eq 0 ]]; then
		echo "0"
		return 0
	fi
	local delta=$(((after - before) * 100 / before))
	echo "$delta"
	return 0
}

# Check whether a label appears in a comma-separated list.
# Returns 0 if found, 1 if not.
_gh_audit_label_in_csv() {
	local label="$1"
	local csv="$2"
	# Wrap csv in commas to ensure exact match
	local wrapped=",${csv},"
	case "$wrapped" in
	*",${label},"*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# Compute labels removed and labels added between two CSV strings.
# Outputs two lines: "removed: l1,l2" and "added: l3"
_gh_audit_label_diff() {
	local before_csv="$1"
	local after_csv="$2"
	local removed="" added=""
	local first=1 label

	# Labels in before but not in after = removed
	local IFS_ORIG="$IFS"
	IFS=','
	for label in $before_csv; do
		IFS="$IFS_ORIG"
		[[ -z "$label" ]] && IFS=',' && continue
		if ! _gh_audit_label_in_csv "$label" "$after_csv"; then
			if [[ "$first" -eq 1 ]]; then
				removed="$label"
				first=0
			else
				removed="${removed},${label}"
			fi
		fi
		IFS=','
	done
	IFS="$IFS_ORIG"

	# Labels in after but not in before = added
	first=1
	IFS=','
	for label in $after_csv; do
		IFS="$IFS_ORIG"
		[[ -z "$label" ]] && IFS=',' && continue
		if ! _gh_audit_label_in_csv "$label" "$before_csv"; then
			if [[ "$first" -eq 1 ]]; then
				added="$label"
				first=0
			else
				added="${added},${label}"
			fi
		fi
		IFS=','
	done
	IFS="$IFS_ORIG"

	echo "removed:$removed"
	echo "added:$added"
	return 0
}

# Compute the suspicious array from state delta.
# Args: title_delta_pct body_delta_pct removed_csv
# Output: JSON array string, e.g. ["title_delta_pct<-50","body_wiped"]
_gh_audit_compute_suspicious() {
	local title_delta_pct="$1"
	local body_delta_pct="$2"
	local removed_csv="$3"
	local signals="" first=1

	# Signal: title shrunk by more than threshold
	if [[ "$title_delta_pct" -lt -"$GH_AUDIT_TITLE_SHRINK_PCT_THRESHOLD" ]]; then
		signals="\"title_delta_pct<-${GH_AUDIT_TITLE_SHRINK_PCT_THRESHOLD}\""
		first=0
	fi

	# Signal: body completely wiped
	if [[ "$body_delta_pct" -le -"$GH_AUDIT_BODY_WIPE_THRESHOLD" ]]; then
		local sig="\"body_delta_pct=-${GH_AUDIT_BODY_WIPE_THRESHOLD}\""
		if [[ "$first" -eq 1 ]]; then
			signals="$sig"
			first=0
		else
			signals="${signals},${sig}"
		fi
	fi

	# Signal: protected label removed
	local plabel
	for plabel in "${GH_AUDIT_PROTECTED_LABELS[@]}"; do
		if [[ -n "$removed_csv" ]] && _gh_audit_label_in_csv "$plabel" "$removed_csv"; then
			local sig="\"protected_label_removed:${plabel}\""
			if [[ "$first" -eq 1 ]]; then
				signals="$sig"
				first=0
			else
				signals="${signals},${sig}"
			fi
		fi
	done

	echo "[${signals}]"
	return 0
}

# Compute anomaly signals when one or both state snapshots were unavailable.
# Args: before_capture_status after_capture_status
# Output: JSON array containing phase-specific capture signals.
_gh_audit_compute_capture_suspicious() {
	local before_capture_status="$1"
	local after_capture_status="$2"
	local signals=""

	if [[ "$before_capture_status" != "$GH_AUDIT_CAPTURE_OK" ]]; then
		signals='"state_capture_unavailable:before"'
	fi
	if [[ "$after_capture_status" != "$GH_AUDIT_CAPTURE_OK" ]]; then
		if [[ -n "$signals" ]]; then
			signals="${signals},\"state_capture_unavailable:after\""
		else
			signals='"state_capture_unavailable:after"'
		fi
	fi

	printf '[%s]\n' "$signals"
	return 0
}

# Classify whether a captured state JSON value is safe to compare.
# Legacy records without capture_status remain comparable when all historical
# fields have their expected types. Missing or null fields are never treated as
# a successfully captured empty state.
# Args: state_json
# Output: ok | unavailable
_gh_audit_state_capture_status() {
	local state_json="$1"
	local status="$GH_AUDIT_CAPTURE_UNAVAILABLE"

	if ! command -v jq &>/dev/null; then
		printf '%s\n' "$status"
		return 0
	fi
	status=$(printf '%s' "$state_json" | jq -r \
		--arg capture_ok "$GH_AUDIT_CAPTURE_OK" \
		--arg capture_unavailable "$GH_AUDIT_CAPTURE_UNAVAILABLE" '
		if ((.capture_status // $capture_ok) == $capture_ok)
			and ((.title_len | type) == "number")
			and ((.body_len | type) == "number")
			and ((.labels | type) == "array")
		then $capture_ok
		else $capture_unavailable
		end
	' 2>/dev/null) || status="$GH_AUDIT_CAPTURE_UNAVAILABLE"
	[[ "$status" == "$GH_AUDIT_CAPTURE_OK" ]] || status="$GH_AUDIT_CAPTURE_UNAVAILABLE"
	printf '%s\n' "$status"
	return 0
}

# Validate that an operation string is in the allowed list.
# Returns 0 if valid, 1 if not.
_gh_audit_validate_op() {
	local op="$1"
	local valid_op
	for valid_op in "${GH_AUDIT_VALID_OPS[@]}"; do
		if [[ "$op" == "$valid_op" ]]; then
			return 0
		fi
	done
	return 1
}

# Rotate old log files: keep at most GH_AUDIT_MAX_ROTATIONS_DEFAULT rotations.
# Called after renaming the active log.
_gh_audit_prune_rotations() {
	local log_dir="$1"
	local log_base="$2"
	local max_rotations="${GH_AUDIT_MAX_ROTATIONS:-${GH_AUDIT_MAX_ROTATIONS_DEFAULT}}"

	# List rotation files sorted oldest-first (lexicographic on timestamp suffix)
	local -a rotation_files=()
	local f
	while IFS= read -r f; do
		rotation_files+=("$f")
	done < <(ls -1 "${log_dir}/${log_base}".* 2>/dev/null | sort)

	local count="${#rotation_files[@]}"
	if [[ "$count" -le "$max_rotations" ]]; then
		return 0
	fi

	local to_delete=$((count - max_rotations))
	local i
	for ((i = 0; i < to_delete; i++)); do
		rm -f "${rotation_files[i]}" 2>/dev/null || true
	done

	return 0
}

# =============================================================================
# Commands
# =============================================================================

# Parse cmd_record arguments into caller-scoped output variables.
# Caller must declare the target variables as `local` before calling.
# Unknown arguments are warned and skipped.
# Returns 0 always (all arg failures are non-fatal).
_cmd_record_parse_args() {
	# Reset output variables in caller scope to known defaults.
	_rr_op="" _rr_repo="" _rr_number=""
	_rr_caller_script="" _rr_caller_function="" _rr_caller_line="0"
	_rr_before_json="" _rr_after_json="" _rr_flags_json="{}"

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--op)
			_rr_op="${2:-}"
			shift 2
			;;
		--repo)
			_rr_repo="${2:-}"
			shift 2
			;;
		--number)
			_rr_number="${2:-}"
			shift 2
			;;
		--before-json)
			_rr_before_json="${2:-}"
			shift 2
			;;
		--after-json)
			_rr_after_json="${2:-}"
			shift 2
			;;
		--caller-script)
			_rr_caller_script="${2:-}"
			shift 2
			;;
		--caller-function)
			_rr_caller_function="${2:-}"
			shift 2
			;;
		--caller-line)
			_rr_caller_line="${2:-0}"
			shift 2
			;;
		--flags-json)
			_rr_flags_json="${2:-}"
			shift 2
			;;
		*)
			_gh_audit_warn "Unknown argument to record: ${_arg} (ignored)"
			shift
			;;
		esac
	done
	return 0
}

# Validate parsed cmd_record args. Applies defaults for optional fields.
# Args: op repo number
# Returns 0 if valid, 1 with warning on fatal error.
_cmd_record_validate_args() {
	local op="$1" repo="$2" number="$3"
	if [[ -z "$op" ]]; then
		_gh_audit_warn "record: --op is required"
		return 1
	fi
	if ! _gh_audit_validate_op "$op"; then
		_gh_audit_warn "record: invalid op '${op}' (valid: ${GH_AUDIT_VALID_OPS[*]})"
		return 1
	fi
	if [[ -z "$repo" ]]; then
		_gh_audit_warn "record: --repo is required"
		return 1
	fi
	if [[ -z "$number" ]] || [[ ! "$number" =~ ^[0-9]+$ ]]; then
		_gh_audit_warn "record: --number must be a positive integer (got '${number}')"
		return 1
	fi
	return 0
}

# Extract delta fields + suspicious signals from before/after JSON.
# Deltas are null and comparable=false when either snapshot is unavailable;
# audit-read failures must never be reported as destructive state changes.
# Populates caller-scoped output vars: _rd_delta_json, _rd_suspicious_json,
# _rd_removed_csv.
# Args: before_json after_json
# Returns 0 always.
_cmd_record_compute_delta() {
	local before_json="$1" after_json="$2"
	local before_title_len=0 before_body_len=0 before_labels_csv=""
	local after_title_len=0 after_body_len=0 after_labels_csv=""
	local before_capture_status after_capture_status
	before_capture_status="$(_gh_audit_state_capture_status "$before_json")"
	after_capture_status="$(_gh_audit_state_capture_status "$after_json")"

	if [[ "$before_capture_status" != "$GH_AUDIT_CAPTURE_OK" || "$after_capture_status" != "$GH_AUDIT_CAPTURE_OK" ]]; then
		if command -v jq &>/dev/null; then
			_rd_delta_json=$(jq -c -n \
				'{comparable: false, title_delta_pct: null, body_delta_pct: null,
				  labels_removed: null, labels_added: null}')
		else
			_rd_delta_json='{"comparable":false,"title_delta_pct":null,"body_delta_pct":null,"labels_removed":null,"labels_added":null}'
		fi
		_rd_suspicious_json="$(_gh_audit_compute_capture_suspicious \
			"$before_capture_status" "$after_capture_status")"
		_rd_removed_csv=""
		return 0
	fi

	if command -v jq &>/dev/null; then
		before_title_len=$(printf '%s' "$before_json" | jq -r '.title_len // 0')
		before_body_len=$(printf '%s' "$before_json" | jq -r '.body_len // 0')
		before_labels_csv=$(printf '%s' "$before_json" | jq -r '.labels // [] | join(",")')
		after_title_len=$(printf '%s' "$after_json" | jq -r '.title_len // 0')
		after_body_len=$(printf '%s' "$after_json" | jq -r '.body_len // 0')
		after_labels_csv=$(printf '%s' "$after_json" | jq -r '.labels // [] | join(",")')
	fi

	local title_delta_pct body_delta_pct
	title_delta_pct="$(_gh_audit_delta_pct "$before_title_len" "$after_title_len")"
	body_delta_pct="$(_gh_audit_delta_pct "$before_body_len" "$after_body_len")"

	local removed_csv="" added_csv=""
	local diff_line
	while IFS= read -r diff_line; do
		case "$diff_line" in
		removed:*) removed_csv="${diff_line#removed:}" ;;
		added:*) added_csv="${diff_line#added:}" ;;
		esac
	done < <(_gh_audit_label_diff "$before_labels_csv" "$after_labels_csv")

	local removed_json added_json
	removed_json="$(_gh_audit_labels_to_json_array "$removed_csv")"
	added_json="$(_gh_audit_labels_to_json_array "$added_csv")"

	if command -v jq &>/dev/null; then
		_rd_delta_json=$(jq -c -n \
			--argjson comparable true \
			--argjson title_delta_pct "$title_delta_pct" \
			--argjson body_delta_pct "$body_delta_pct" \
			--argjson labels_removed "$removed_json" \
			--argjson labels_added "$added_json" \
			'{comparable: $comparable, title_delta_pct: $title_delta_pct, body_delta_pct: $body_delta_pct,
			  labels_removed: $labels_removed, labels_added: $labels_added}')
	else
		_rd_delta_json="{\"comparable\":true,\"title_delta_pct\":${title_delta_pct},\"body_delta_pct\":${body_delta_pct},\"labels_removed\":${removed_json},\"labels_added\":${added_json}}"
	fi

	_rd_suspicious_json="$(_gh_audit_compute_suspicious \
		"$title_delta_pct" "$body_delta_pct" "$removed_csv")"
	_rd_removed_csv="$removed_csv"

	return 0
}

# Build the NDJSON event string from parsed + computed fields.
# Args: ts op repo number caller_script caller_function caller_line
#       flags_json before_json after_json delta_json suspicious_json
# Output: NDJSON event on stdout.
_cmd_record_build_event_json() {
	local ts="$1" op="$2" repo="$3" number="$4"
	local caller_script="$5" caller_function="$6" caller_line="$7"
	local flags_json="$8" before_json="$9" after_json="${10}"
	local delta_json="${11}" suspicious_json="${12}"

	if command -v jq &>/dev/null; then
		jq -c -n \
			--arg ts "$ts" \
			--arg op "$op" \
			--arg repo "$repo" \
			--argjson number "$number" \
			--arg caller_script "$caller_script" \
			--arg caller_function "$caller_function" \
			--argjson caller_line "$caller_line" \
			--argjson pid $$ \
			--argjson flags "$flags_json" \
			--argjson before "$before_json" \
			--argjson after "$after_json" \
			--argjson delta "$delta_json" \
			--argjson suspicious "$suspicious_json" \
			'{ts: $ts, op: $op, repo: $repo, number: $number,
			  caller_script: $caller_script, caller_function: $caller_function,
			  caller_line: $caller_line, pid: $pid, flags: $flags,
			  before: $before, after: $after, delta: $delta,
			  suspicious: $suspicious}'
		return 0
	fi

	local esc_op esc_repo esc_caller_script esc_caller_function
	esc_op="$(_gh_audit_json_escape "$op")"
	esc_repo="$(_gh_audit_json_escape "$repo")"
	esc_caller_script="$(_gh_audit_json_escape "$caller_script")"
	esc_caller_function="$(_gh_audit_json_escape "$caller_function")"
	printf '%s\n' "{\"ts\":\"${ts}\",\"op\":\"${esc_op}\",\"repo\":\"${esc_repo}\",\"number\":${number},\"caller_script\":\"${esc_caller_script}\",\"caller_function\":\"${esc_caller_function}\",\"caller_line\":${caller_line},\"pid\":$$,\"flags\":${flags_json},\"before\":${before_json},\"after\":${after_json},\"delta\":${delta_json},\"suspicious\":${suspicious_json}}"
	return 0
}

# Parse arguments and write one NDJSON event to gh-audit.log.
#
# Required args:
#   --op OP          — operation type (see GH_AUDIT_VALID_OPS)
#   --repo REPO      — owner/repo
#   --number N       — issue or PR number
#
# Optional args (all have safe defaults):
#   --before-json J  — captured state object (omitted/invalid = unavailable)
#   --after-json J   — captured state object (omitted/invalid = unavailable)
#   --caller-script F
#   --caller-function FUNC
#   --caller-line N
#   --flags-json J   — JSON object of relevant env vars
cmd_record() {
	# Parsed args (populated by _cmd_record_parse_args via global-scope vars
	# within cmd_record's local frame).
	local _rr_op _rr_repo _rr_number
	local _rr_caller_script _rr_caller_function _rr_caller_line
	local _rr_before_json _rr_after_json _rr_flags_json

	_cmd_record_parse_args "$@"

	if ! _cmd_record_validate_args "$_rr_op" "$_rr_repo" "$_rr_number"; then
		return 1
	fi

	# Apply defaults for optional fields. Missing or malformed snapshots remain
	# explicit gaps in audit visibility instead of synthetic empty GitHub state.
	[[ -z "$_rr_before_json" ]] && _rr_before_json="$GH_AUDIT_UNAVAILABLE_STATE_JSON"
	[[ -z "$_rr_after_json" ]] && _rr_after_json="$GH_AUDIT_UNAVAILABLE_STATE_JSON"
	if command -v jq &>/dev/null; then
		if ! printf '%s' "$_rr_before_json" | jq -e 'type == "object"' &>/dev/null; then
			_rr_before_json="$GH_AUDIT_UNAVAILABLE_STATE_JSON"
		fi
		if ! printf '%s' "$_rr_after_json" | jq -e 'type == "object"' &>/dev/null; then
			_rr_after_json="$GH_AUDIT_UNAVAILABLE_STATE_JSON"
		fi
	fi
	[[ -z "$_rr_caller_script" ]] && _rr_caller_script="unknown"
	[[ -z "$_rr_caller_function" ]] && _rr_caller_function="unknown"
	[[ ! "$_rr_caller_line" =~ ^[0-9]+$ ]] && _rr_caller_line=0

	# Compute delta + suspicious fields (populates _rd_* locals).
	local _rd_delta_json _rd_suspicious_json _rd_removed_csv
	_cmd_record_compute_delta "$_rr_before_json" "$_rr_after_json"

	# Validate flags_json parses as JSON; reset to "{}" if not.
	if command -v jq &>/dev/null; then
		if ! printf '%s' "$_rr_flags_json" | jq -e '.' &>/dev/null; then
			_rr_flags_json="{}"
		fi
	fi

	local ts event
	ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"
	event="$(_cmd_record_build_event_json \
		"$ts" "$_rr_op" "$_rr_repo" "$_rr_number" \
		"$_rr_caller_script" "$_rr_caller_function" "$_rr_caller_line" \
		"$_rr_flags_json" "$_rr_before_json" "$_rr_after_json" \
		"$_rd_delta_json" "$_rd_suspicious_json")"

	_gh_audit_ensure_log

	local log_file
	log_file="$(_gh_audit_log_path)"

	# Check if rotation is needed before appending (audit errors never block).
	cmd_rotate --check-only 2>/dev/null || true

	echo "$event" >>"$log_file"

	if [[ "$_rd_suspicious_json" != "[]" ]]; then
		_gh_audit_warn "ANOMALY detected in ${_rr_op} on ${_rr_repo}#${_rr_number}: ${_rd_suspicious_json}"
	else
		_gh_audit_info "Recorded ${_rr_op} on ${_rr_repo}#${_rr_number}"
	fi

	return 0
}

# Rotate the gh-audit.log if it exceeds the size threshold.
# Keeps last GH_AUDIT_MAX_ROTATIONS_DEFAULT rotations.
# Arguments:
#   --max-size MB     Override threshold (default: GH_AUDIT_MAX_SIZE_MB_DEFAULT)
#   --check-only      Only rotate if needed; exit 0 either way (used internally)
cmd_rotate() {
	local max_size_mb="${GH_AUDIT_MAX_SIZE_MB:-${GH_AUDIT_MAX_SIZE_MB_DEFAULT}}"
	local check_only=0

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--max-size)
			max_size_mb="${2:-${GH_AUDIT_MAX_SIZE_MB_DEFAULT}}"
			if [[ ! "$max_size_mb" =~ ^[0-9]+$ ]]; then
				_gh_audit_warn "rotate: --max-size must be a positive integer"
				return 1
			fi
			shift 2
			;;
		--check-only)
			check_only=1
			shift
			;;
		*)
			shift
			;;
		esac
	done

	local log_file
	log_file="$(_gh_audit_log_path)"

	if [[ ! -f "$log_file" ]]; then
		return 0
	fi

	local size_bytes
	size_bytes="$(_gh_audit_byte_count "$log_file")"
	local max_size_bytes=$((max_size_mb * 1048576))

	if [[ "$size_bytes" -lt "$max_size_bytes" ]]; then
		return 0
	fi

	if [[ "$check_only" -eq 1 ]]; then
		# Run rotation now
		true
	fi

	local rotate_ts
	rotate_ts="$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%dT%H%M%SZ')"
	local log_dir
	log_dir="$(dirname "$log_file")"
	local log_basename
	log_basename="$(basename "$log_file")"
	local rotated_file="${log_dir}/${log_basename%.log}.${rotate_ts}.log"

	mv "$log_file" "$rotated_file" 2>/dev/null || return 0
	chmod 400 "$rotated_file" || true

	local entry_count
	entry_count="$(_gh_audit_line_count "$rotated_file")" || entry_count=0

	_gh_audit_info "Rotated to ${rotated_file} (${entry_count} entries, ${size_bytes} bytes)"

	# Prune old rotations
	_gh_audit_prune_rotations "$log_dir" "$log_basename"

	return 0
}

# Show log status: size, entry count, last entry, anomaly count.
cmd_status() {
	local log_file
	log_file="$(_gh_audit_log_path)"

	echo "GH Audit Log Status"
	echo "==================="
	echo "Version:  ${GH_AUDIT_VERSION}"
	echo "Log file: ${log_file}"

	if [[ ! -f "$log_file" ]]; then
		echo "Status:   No log file (will be created on first record call)"
		return 0
	fi

	local size_bytes entry_count
	size_bytes="$(_gh_audit_byte_count "$log_file")"
	entry_count="$(_gh_audit_line_count "$log_file")"

	local size_human
	if [[ "$size_bytes" -gt 1048576 ]]; then
		size_human="$((size_bytes / 1048576)) MB"
	elif [[ "$size_bytes" -gt 1024 ]]; then
		size_human="$((size_bytes / 1024)) KB"
	else
		size_human="${size_bytes} bytes"
	fi

	echo "Entries:  ${entry_count}"
	echo "Size:     ${size_human}"

	if [[ "$entry_count" -gt 0 ]] && command -v jq &>/dev/null; then
		local first_ts last_ts
		first_ts="$(head -1 "$log_file" | jq -r '.ts // "unknown"' 2>/dev/null || echo "unknown")"
		last_ts="$(tail -1 "$log_file" | jq -r '.ts // "unknown"' 2>/dev/null || echo "unknown")"
		echo "First:    ${first_ts}"
		echo "Last:     ${last_ts}"

		# -c compact output so wc -l counts entries, not pretty-printed lines.
		local anomaly_count
		anomaly_count="$(jq -c 'select(.suspicious | length > 0)' "$log_file" 2>/dev/null | wc -l | tr -d '[:space:]')" || anomaly_count=0
		echo "Anomalies: ${anomaly_count}"

		echo ""
		echo "Operation breakdown:"
		jq -r '.op' "$log_file" 2>/dev/null | sort | uniq -c | sort -rn | while IFS= read -r line; do
			echo "  $line"
		done
	fi

	return 0
}

cmd_help() {
	cat <<'HELP'
gh-audit-log-helper.sh — Structured audit log for destructive GitHub operations

Records every destructive gh operation (issue_edit, issue_close, issue_reopen,
pr_edit, pr_close, pr_merge) with before/after state and anomaly signals.

Commands:
  record [--op OP] [--repo REPO] [--number N] \
    [--before-json J] [--after-json J] \
    [--caller-script F] [--caller-function F] [--caller-line N]
                                    Append one NDJSON audit event
  status                            Show log status and statistics
  rotate [--max-size MB]            Rotate log if over threshold (default 10 MB)
  help                              Show this help

Operations (--op values):
  issue_edit     gh issue edit was called
  issue_close    gh issue close was called
  issue_reopen   gh issue reopen was called
  pr_edit        gh pr edit was called
  pr_close       gh pr close was called
  pr_merge       gh pr merge was called

Anomaly signals (appear in suspicious[]):
  title_delta_pct<-50    Title shrunk by more than 50%
  body_delta_pct=-100    Body completely wiped
  protected_label_removed:<label>  A protected label was removed

Environment:
  GH_AUDIT_LOG_FILE       Override log file path
  GH_AUDIT_QUIET          Suppress informational output ("true")
  GH_AUDIT_MAX_SIZE_MB    Rotation threshold in MB (default: 10)
  GH_AUDIT_MAX_ROTATIONS  Max rotation files to keep (default: 10)

Log path: ~/.aidevops/logs/gh-audit.log
Docs:     reference/gh-audit-log.md
HELP
	return 0
}

# =============================================================================
# Main dispatch
# =============================================================================

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	record)
		cmd_record "$@"
		;;
	status)
		cmd_status "$@"
		;;
	rotate)
		cmd_rotate "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		_gh_audit_warn "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
