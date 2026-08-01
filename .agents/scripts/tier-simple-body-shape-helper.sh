#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# tier-simple-body-shape-helper.sh — Normalize tier:simple issues that lack
# an explicit simple execution contract before worker dispatch (t2389).
#
# Runs between _ensure_issue_body_has_brief and _run_predispatch_validator
# in pulse-dispatch-core.sh::dispatch_with_dedup. Only activates for issues
# carrying the tier:simple label. It enforces only mechanically provable
# contract invariants: a present checklist must be complete, and the body must
# contain matched oldString/newString blocks, complete new-file content, or an
# exact deterministic transform. Counts, estimates, and keywords are not gates.
#
# Non-blocking by design: always exits 0 regardless of outcome. The worker
# is always dispatched — at the correct tier if a disqualifier was found,
# at tier:simple otherwise. No issue is ever closed by this helper.
#
# Exit codes (check subcommand):
#   0  — always (non-blocking)
#
# Usage:
#   tier-simple-body-shape-helper.sh check <issue-number> <slug>
#   tier-simple-body-shape-helper.sh help
#
# Bypass:
#   AIDEVOPS_SKIP_TIER_VALIDATOR=1 — exit 0 immediately (with log)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

readonly TIER_LABELS_MUTATED_MARKER='[aidevops:tier-labels-mutated]'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log() {
	local level="$1"
	shift
	printf '[tier-simple-validator] %s: %s\n' "$level" "$*" >&2
	return 0
}

# ---------------------------------------------------------------------------
# Check 1: a present tier checklist must have no unchecked items.
# Absence is allowed for legacy/manual issue bodies; the execution-contract check
# below still applies. Returns 0 on pass, 10 on explicit contract failure.
# ---------------------------------------------------------------------------
_check_tier_checklist() {
	local body="$1"

	local checklist
	checklist=$(printf '%s\n' "$body" | awk '
		BEGIN { in_section = 0 }
		/^###[[:space:]]+Tier[[:space:]]+checklist([[:space:]].*)?$/ {
			in_section = 1
			next
		}
		in_section && /^\*\*Selected tier:\*\*/ { exit }
		in_section && /^##[[:space:]]/ { exit }
		in_section { print }
	')
	if [[ -z "$checklist" ]]; then
		return 0
	fi

	local unchecked_count
	unchecked_count=$(printf '%s\n' "$checklist" | grep -cE '^[[:space:]]*-[[:space:]]+\[[[:space:]]\]' || true)
	unchecked_count=${unchecked_count:-0}
	if [[ "$unchecked_count" -gt 0 ]]; then
		DISQUALIFIER_REASON="tier:simple checklist incomplete"
		DISQUALIFIER_EVIDENCE="The Tier checklist contains ${unchecked_count} unchecked item(s). tier:simple requires every explicit simple-contract condition to be proven."
		return 10
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Check 2: exact execution contract is present and internally paired.
# Existing-file replacements require matched oldString/newString counts. New
# files use Full content; deterministic rename/move/delete work uses Exact
# transform. Returns 0 on pass, 10 on explicit contract failure.
# ---------------------------------------------------------------------------
_check_execution_contract() {
	local body="$1"

	local old_count new_count full_count transform_count
	old_count=$(printf '%s\n' "$body" | grep -cE '^\*\*oldString:\*\*[[:space:]]*$' || true)
	new_count=$(printf '%s\n' "$body" | grep -cE '^\*\*newString:\*\*[[:space:]]*$' || true)
	full_count=$(printf '%s\n' "$body" | grep -cE '^\*\*Full content:\*\*[[:space:]]*$' || true)
	transform_count=$(printf '%s\n' "$body" | grep -cE '^\*\*Exact transform:\*\*[[:space:]]*' || true)
	old_count=${old_count:-0}
	new_count=${new_count:-0}
	full_count=${full_count:-0}
	transform_count=${transform_count:-0}

	if [[ "$old_count" -ne "$new_count" ]]; then
		DISQUALIFIER_REASON="oldString/newString contract is unpaired"
		DISQUALIFIER_EVIDENCE="The body contains ${old_count} oldString marker(s) and ${new_count} newString marker(s). Every tier:simple replacement requires a matched pair."
		return 10
	fi
	if [[ "$old_count" -eq 0 && "$full_count" -eq 0 && "$transform_count" -eq 0 ]]; then
		DISQUALIFIER_REASON="exact execution contract missing"
		DISQUALIFIER_EVIDENCE="The body has no matched oldString/newString replacement, Full content block, or Exact transform. tier:simple requires one of these explicit contracts."
		return 10
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Apply the downgrade: swap tier:simple → tier:standard + post feedback.
#
# Idempotent via the <!-- tier-simple-auto-downgrade --> marker. If the
# marker is already present in any comment, skip the comment post but
# still ensure the label swap is applied (in case it was reverted).
#
# Fails open: if the API call fails, dispatch still proceeds — the worker
# will either succeed at tier:simple (and the body-shape check was a false
# positive) or fail and cascade up normally.
# ---------------------------------------------------------------------------
_apply_downgrade() {
	local slug="$1"
	local issue_num="$2"
	local reason="$3"
	local evidence="$4"

	local marker='<!-- tier-simple-auto-downgrade -->'

	# Swap the label first. If this fails, skip the comment (no point
	# telling the maintainer we downgraded if we didn't actually downgrade).
	if ! gh issue edit "$issue_num" --repo "$slug" \
		--remove-label "tier:simple" --add-label "tier:standard" \
		>/dev/null 2>&1; then
		_log "WARN" "failed to swap tier labels on #${issue_num} in ${slug} — skipping feedback comment"
		return 0
	fi
	printf '%s\n' "$TIER_LABELS_MUTATED_MARKER"

	_log "INFO" "downgraded #${issue_num} in ${slug}: tier:simple → tier:standard (${reason})"

	# Idempotency check for the feedback comment.
	local existing=""
	existing=$(gh api "repos/${slug}/issues/${issue_num}/comments" \
		--jq "[.[] | select(.body | contains(\"${marker}\"))] | length" \
		2>/dev/null) || existing=""
	if [[ "$existing" =~ ^[1-9][0-9]*$ ]]; then
		_log "INFO" "feedback comment already present on #${issue_num} — skipping post"
		return 0
	fi

	local comment_body="${marker}
## Tier Auto-Downgrade: simple → standard

Pre-dispatch contract check found that this issue does not satisfy the explicit \`tier:simple\` execution contract. Swapped \`tier:simple\` → \`tier:standard\` before worker dispatch.

**Disqualifier:** ${reason}

**Evidence:** ${evidence}

The worker is still dispatching — just at the normalized tier. See \`.agents/reference/task-taxonomy.md\` \"Canonical Assignment Policy\".

_Automated by \`tier-simple-body-shape-helper.sh\` (t2389). Posted once per issue via the \`${marker}\` marker; re-runs are no-ops._"

	gh_issue_comment "$issue_num" --repo "$slug" --body "$comment_body" \
		>/dev/null 2>&1 || _log "WARN" "feedback comment post failed on #${issue_num} — label swap still applied"

	return 0
}

# ---------------------------------------------------------------------------
# Main check entry point.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#
# Returns 0 always (non-blocking by design).
# ---------------------------------------------------------------------------
cmd_check() {
	local issue_num="$1"
	local slug="$2"

	[[ "$issue_num" =~ ^[0-9]+$ ]] || {
		_log "WARN" "invalid issue number: ${issue_num}"
		return 0
	}
	[[ -n "$slug" ]] || {
		_log "WARN" "empty slug"
		return 0
	}

	# Bypass for emergency recovery.
	if [[ "${AIDEVOPS_SKIP_TIER_VALIDATOR:-0}" == "1" ]]; then
		_log "INFO" "AIDEVOPS_SKIP_TIER_VALIDATOR=1 — bypassing check for #${issue_num}"
		return 0
	fi

	# Fetch labels + body in a single round-trip.
	local issue_json
	issue_json=$(gh issue view "$issue_num" --repo "$slug" \
		--json labels,body 2>/dev/null) || {
		_log "WARN" "gh issue view failed for #${issue_num} in ${slug} — skipping check"
		return 0
	}

	# Only activate for tier:simple.
	local has_simple
	has_simple=$(printf '%s' "$issue_json" | \
		jq -r '[.labels[].name] | any(. == "tier:simple")' 2>/dev/null) || has_simple="false"
	if [[ "$has_simple" != "true" ]]; then
		return 0
	fi

	local body
	body=$(printf '%s' "$issue_json" | jq -r '.body // ""' 2>/dev/null) || body=""
	if [[ -z "$body" ]]; then
		_log "INFO" "empty body on #${issue_num} — nothing to check"
		return 0
	fi

	# Run mechanically provable checks only. First hit wins because every failure
	# normalizes to tier:standard.
	DISQUALIFIER_REASON=""
	DISQUALIFIER_EVIDENCE=""

	local check
	for check in _check_tier_checklist _check_execution_contract; do
		local rc=0
		"$check" "$body" || rc=$?
		if [[ "$rc" -eq 10 ]]; then
			_apply_downgrade "$slug" "$issue_num" \
				"$DISQUALIFIER_REASON" "$DISQUALIFIER_EVIDENCE"
			return 0
		fi
	done

	_log "INFO" "#${issue_num} in ${slug}: tier:simple execution contract is explicit"
	return 0
}

# ---------------------------------------------------------------------------
# Usage help
# ---------------------------------------------------------------------------
cmd_help() {
	cat <<'EOF'
tier-simple-body-shape-helper.sh — Normalize tier:simple issues that lack an
explicit execution contract (t2389).

Usage:
  tier-simple-body-shape-helper.sh check <issue-number> <slug>
  tier-simple-body-shape-helper.sh help

Commands:
  check    Inspect explicit checklist and execution-contract markers; on
           failure, swap tier:simple → tier:standard and post feedback.
  help     Print this message.

Exit codes:
  0        Always (non-blocking by design — never stops dispatch).

Bypass:
  AIDEVOPS_SKIP_TIER_VALIDATOR=1 to exit 0 immediately without checking.

See .agents/reference/task-taxonomy.md "Canonical Assignment Policy".
Open-ended tier judgment remains at task creation; this helper enforces only
mechanically provable simple-contract invariants.
EOF
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	local subcmd="${1:-help}"
	shift || true

	case "$subcmd" in
		check)
			if [[ $# -lt 2 ]]; then
				_log "ERROR" "check requires <issue-number> <slug>"
				return 1
			fi
			cmd_check "$1" "$2"
			;;
		help|--help|-h)
			cmd_help
			;;
		*)
			_log "ERROR" "unknown subcommand: ${subcmd}"
			cmd_help >&2
			return 1
			;;
	esac
	return 0
}

# Allow sourcing without executing (for test harnesses).
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
	main "$@"
fi
