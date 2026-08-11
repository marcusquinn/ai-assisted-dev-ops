#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-label-invariants.sh — t2040 regression guard.
#
# Asserts the three components of the label-invariant subsystem work:
#
#   Part 1 — ISSUE_STATUS_LABEL_PRECEDENCE + ISSUE_TIER_LABEL_RANK
#            arrays are present in shared-constants.sh with the correct
#            order and 'done' as terminal.
#
#   Part 2 — _mark_issue_done() in issue-sync-helper.sh issues exactly
#            one `gh issue edit` call (atomic) and sets status:done
#            via set_issue_status passthrough.
#
#   Part 3 — _normalize_label_invariants() in pulse-issue-reconcile.sh:
#            * dual-status reduction picks the highest-precedence label
#            * 'done' is always preserved (terminal)
#            * triple-tier reduction picks the highest-rank tier
#            * single-label issues are a no-op
#            * triage-missing issues are counted (not auto-fixed)
#            * counter file is written after the pass
#
# Failure history: PR #18519 (t2033) and PR #18441 (t1997) fixed the
# forward paths for the write-without-remove status bug and the
# tier-concatenation enrich bug, but 14 already-polluted issues
# (9 dual-status + 5 multi-tier) needed backfill. This test guards
# against regression on both the precedence logic and the backfill path.

set -uo pipefail

# Keep the gh_issue_list-backed reconciler fixture on the mocked GraphQL path.
# Developer shells may export REST-first read mode; that bypasses this test's
# minimal `gh issue list` stub and makes the invariant rows appear empty.
unset AIDEVOPS_GH_REST_FIRST_READS
unset AIDEVOPS_GH_FORCE_REST_READS

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
}

find_label_color() {
	local array_name="$1" label_name="$2"
	local definitions=()
	local definition name color desc

	eval "definitions=(\"\${${array_name}[@]}\")"
	for definition in "${definitions[@]}"; do
		IFS='|' read -r name color desc <<<"$definition"
		if [[ "$name" == "$label_name" ]]; then
			printf '%s\n' "$color"
			return 0
		fi
	done
	return 1
}

# Sandbox HOME — side-effect-free sourcing + isolate cache writes
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor" "${HOME}/.aidevops/cache"
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
: >"$LOGFILE"

# =============================================================================
# Part 1 — precedence arrays exist and are correct
# =============================================================================
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/label-sync-helper.sh"
set +e

if [[ -n "${ISSUE_STATUS_LABEL_PRECEDENCE+x}" ]]; then
	print_result "ISSUE_STATUS_LABEL_PRECEDENCE is defined" 0
else
	print_result "ISSUE_STATUS_LABEL_PRECEDENCE is defined" 1 "(not set)"
fi

if [[ "${ISSUE_STATUS_LABEL_PRECEDENCE[0]:-}" == "done" ]]; then
	print_result "ISSUE_STATUS_LABEL_PRECEDENCE[0] is 'done' (terminal)" 0
else
	print_result "ISSUE_STATUS_LABEL_PRECEDENCE[0] is 'done' (terminal)" 1 \
		"(got: '${ISSUE_STATUS_LABEL_PRECEDENCE[0]:-}')"
fi

# Every core status label must appear in precedence
all_present=1
for core in "${ISSUE_STATUS_LABELS[@]}"; do
	found=0
	for p in "${ISSUE_STATUS_LABEL_PRECEDENCE[@]}"; do
		if [[ "$p" == "$core" ]]; then
			found=1
			break
		fi
	done
	if [[ "$found" -eq 0 ]]; then
		all_present=0
		break
	fi
done
if [[ "$all_present" -eq 1 ]]; then
	print_result "every core status label is in the precedence array" 0
else
	print_result "every core status label is in the precedence array" 1 \
		"(missing core label '$core')"
fi

if [[ -n "${ISSUE_TIER_LABEL_RANK+x}" && "${ISSUE_TIER_LABEL_RANK[0]:-}" == "thinking" &&
	"${ISSUE_TIER_LABEL_RANK[1]:-}" == "standard" && "${ISSUE_TIER_LABEL_RANK[2]:-}" == "simple" ]]; then
	print_result "ISSUE_TIER_LABEL_RANK matches dedup-tier-labels.yml order" 0
else
	print_result "ISSUE_TIER_LABEL_RANK matches dedup-tier-labels.yml order" 1 \
		"(got: ${ISSUE_TIER_LABEL_RANK[*]:-})"
fi

attention_labels=(
	"SYSTEM_LABELS:needs-maintainer-review"
	"SYSTEM_LABELS:security"
	"SYSTEM_LABELS:security-adjacent"
	"SYSTEM_LABELS:critical"
	"PRIORITY_LABELS:priority:critical"
	"STATUS_LABELS:status:blocked"
	"SYSTEM_LABELS:hold-for-review"
	"SYSTEM_LABELS:security-review"
	"SYSTEM_LABELS:needs-review"
	"SYSTEM_LABELS:needs-review-fixes"
)

for attention_spec in "${attention_labels[@]}"; do
	attention_array="${attention_spec%%:*}"
	attention_name="${attention_spec#*:}"
	attention_color=$(find_label_color "$attention_array" "$attention_name" 2>/dev/null || true)
	if [[ "$attention_color" == "D73A4A" ]]; then
		print_result "canonical human-attention label $attention_name is red" 0
	else
		print_result "canonical human-attention label $attention_name is red" 1 "(got: '${attention_color:-missing}')"
	fi
done

origin_labels=(origin:interactive origin:worker origin:worker-takeover)
for origin_name in "${origin_labels[@]}"; do
	origin_color=$(find_label_color "ORIGIN_LABELS" "$origin_name" 2>/dev/null || true)
	if [[ "$origin_color" == "1D76DB" ]]; then
		print_result "canonical origin label $origin_name is blue" 0
	else
		print_result "canonical origin label $origin_name is blue" 1 "(got: '${origin_color:-missing}')"
	fi
done

review_labels=(
	"review:approve|0E8A16"
	"review:feedback|FBCA04"
	"review:decline|D73A4A"
)
for review_spec in "${review_labels[@]}"; do
	review_name="${review_spec%%|*}"
	review_expected_color="${review_spec#*|}"
	review_color=$(find_label_color "SYSTEM_LABELS" "$review_name" 2>/dev/null || true)
	if [[ "$review_color" == "$review_expected_color" ]]; then
		print_result "canonical advisory label $review_name has expected color" 0
	else
		print_result "canonical advisory label $review_name has expected color" 1 \
			"(got: '${review_color:-missing}')"
	fi
done

security_tag_color=$(color_for_tag "security-adjacent")
if [[ "$security_tag_color" == "D73A4A" ]]; then
	print_result "security-adjacent TODO tag maps to red" 0
else
	print_result "security-adjacent TODO tag maps to red" 1 "(got: '$security_tag_color')"
fi

# =============================================================================
# Part 2 — _mark_issue_done delegates to set_issue_status (single gh call)
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"

# Stub gh that logs every invocation to a file so we can count calls.
GH_CALLS="${TEST_ROOT}/gh-calls.log"
: >"$GH_CALLS"
cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh — logs every call to $GH_CALLS and returns success
printf '%s\n' "$*" >>"${GH_CALLS}"
case "$1" in
	api)
		# issue-sync-helper.sh sources shared-constants.sh which references
		# `gh api user --jq '.login'`. Return a placeholder login.
		if [[ "$2" == "user" ]]; then
			echo '{"login":"test-user"}'
			exit 0
		fi
		if [[ "$2" == /repos/*/labels\?per_page=100 ]]; then
			printf '%s\t%s\t%s\n' \
				"status:available" "0e8a16" "Task is available for claiming" \
				"status:queued" "fbca04" "Worker dispatched, not yet started" \
				"status:claimed" "f9d0c4" "Interactive session claimed this task" \
				"status:in-progress" "1d76db" "Worker actively running" \
				"status:in-review" "5319e7" "PR open, awaiting review/merge" \
				"status:done" "6f42c1" "Task is complete" \
				"status:blocked" "d93f0b" "Waiting on blocker task"
			exit 0
		fi
		# Force the compatibility path; REST-first behavior has a dedicated
		# production-wrapper test in test-status-label-state-machine.sh.
		[[ "$2" == /repos/*/issues/[0-9]* ]] && exit 1
		;;
	label)
		# gh label create (used by ensure_status_labels_exist)
		exit 0
		;;
	issue)
		case "$2" in
			edit) exit 0 ;;
			view) echo '{"state":"OPEN","labels":[]}'; exit 0 ;;
			list) echo '[]'; exit 0 ;;
		esac
		;;
esac
exit 0
STUB
chmod +x "${STUB_DIR}/gh"
export GH_CALLS

# Source issue-sync-helper.sh to get _mark_issue_done + set_issue_status.
# NOTE: issue-sync-helper.sh line 29 prepends /usr/local/bin:/usr/bin:/bin
# to PATH on source, so we must re-prepend STUB_DIR AFTER sourcing or the
# real gh wins.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/issue-sync-helper.sh" >/dev/null 2>&1
set +e
export PATH="${STUB_DIR}:${PATH}"

# Call _mark_issue_done — should produce exactly ONE `issue edit` call
: >"$GH_CALLS"
_mark_issue_done "owner/repo" "12345" >/dev/null 2>&1
edit_calls=$(safe_grep_count '^issue edit' "$GH_CALLS")
# Trim whitespace and ensure numeric
edit_calls="${edit_calls//[^0-9]/}"
edit_calls="${edit_calls:-0}"
if [[ "$edit_calls" -eq 1 ]]; then
	print_result "_mark_issue_done makes exactly ONE gh issue edit call (atomic)" 0
else
	print_result "_mark_issue_done makes exactly ONE gh issue edit call (atomic)" 1 \
		"(got $edit_calls edit calls; log: $(cat "$GH_CALLS"))"
fi

# That single edit must add status:done and remove every sibling status
edit_line=$(grep '^issue edit' "$GH_CALLS" | head -1)
if [[ "$edit_line" == *"--add-label status:done"* ]]; then
	print_result "_mark_issue_done atomic edit adds status:done" 0
else
	print_result "_mark_issue_done atomic edit adds status:done" 1 "(line: '$edit_line')"
fi

if [[ "$edit_line" == *"--remove-label status:in-review"* &&
	"$edit_line" == *"--remove-label status:in-progress"* &&
	"$edit_line" == *"--remove-label status:queued"* ]]; then
	print_result "_mark_issue_done atomic edit removes all sibling status labels" 0
else
	print_result "_mark_issue_done atomic edit removes all sibling status labels" 1 \
		"(line: '$edit_line')"
fi

# And it must also clear status:verify-failed (t2040 migration preserved this)
if [[ "$edit_line" == *"--remove-label status:verify-failed"* ]]; then
	print_result "_mark_issue_done clears status:verify-failed" 0
else
	print_result "_mark_issue_done clears status:verify-failed" 1 "(line: '$edit_line')"
fi

# =============================================================================
# Part 3 — _normalize_label_invariants reconciler pass
# =============================================================================
# Fresh gh stub that returns a synthetic issue list, then records edit
# calls so we can assert which issues were fixed.
REPOS_JSON_FILE="${TEST_ROOT}/repos.json"
cat >"$REPOS_JSON_FILE" <<'JSON'
{
	"initialized_repos": [
		{"slug": "test/repo", "pulse": true, "local_only": false}
	],
	"git_parent_dirs": []
}
JSON
export REPOS_JSON="$REPOS_JSON_FILE"
export PULSE_QUEUED_SCAN_LIMIT=100

# Synthesize an issue list covering every reconciler case:
#   #1: dual-status (available + queued) → keep queued (precedence)
#   #2: triple-status with 'done' (done + in-review + in-progress) → keep done (terminal)
#   #3: multi-tier (simple + standard + thinking) → keep thinking
#   #4: dual-status with 'blocked' (blocked + queued) → keep queued (blocked is lowest)
#   #5: single status → no-op
#   #6: triage-missing (origin:interactive, no tier, no auto-dispatch, no status, old)
#   #7: triage-missing-but-recent → not counted
#   #8: triage-missing-but-has-tier → not counted
#   #9: triage-missing shape but routine-tracking non-task → not counted
#   #10: triage-missing shape but supervisor non-task → not counted
#   #11/#12: null/missing labels → no jq error and no edits
#   #13: auto-dispatch missing tier → conservative tier:standard backfill
#   #14: auto-dispatch + no-auto-dispatch missing tier → backfill without
#         clearing the explicit hold
OLD_ISO=$(date -u -d '-1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
	TZ=UTC date -v-1H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "2026-04-13T00:00:00Z")
NEW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

ISSUES_JSON=$(
	cat <<JSON
[
	{"number":1,"labels":[{"name":"status:available"},{"name":"status:queued"},{"name":"tier:standard"}],"createdAt":"${OLD_ISO}"},
	{"number":2,"labels":[{"name":"status:done"},{"name":"status:in-review"},{"name":"status:in-progress"}],"createdAt":"${OLD_ISO}"},
	{"number":3,"labels":[{"name":"tier:simple"},{"name":"tier:standard"},{"name":"tier:thinking"}],"createdAt":"${OLD_ISO}"},
	{"number":4,"labels":[{"name":"status:blocked"},{"name":"status:queued"}],"createdAt":"${OLD_ISO}"},
	{"number":5,"labels":[{"name":"status:available"},{"name":"tier:standard"}],"createdAt":"${OLD_ISO}"},
	{"number":6,"labels":[{"name":"origin:interactive"}],"createdAt":"${OLD_ISO}"},
	{"number":7,"labels":[{"name":"origin:interactive"}],"createdAt":"${NEW_ISO}"},
	{"number":8,"labels":[{"name":"origin:interactive"},{"name":"tier:standard"}],"createdAt":"${OLD_ISO}"},
	{"number":9,"labels":[{"name":"origin:interactive"},{"name":"routine-tracking"}],"createdAt":"${OLD_ISO}"},
	{"number":10,"labels":[{"name":"origin:interactive"},{"name":"supervisor"}],"createdAt":"${OLD_ISO}"},
	{"number":11,"labels":null,"createdAt":"${OLD_ISO}"},
	{"number":12,"createdAt":"${OLD_ISO}"},
	{"number":13,"labels":[{"name":"auto-dispatch"},{"name":"needs-maintainer-review"}],"createdAt":"${OLD_ISO}"},
	{"number":14,"labels":[{"name":"auto-dispatch"},{"name":"no-auto-dispatch"}],"createdAt":"${OLD_ISO}"}
]
JSON
)
ISSUES_JSON_FILE="${TEST_ROOT}/issues.json"
printf '%s\n' "$ISSUES_JSON" >"$ISSUES_JSON_FILE"
export ISSUES_JSON_FILE

cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_CALLS}"
case "$1" in
	api)
		# api user --jq '.login'
		if [[ "$2" == "user" ]]; then
			echo "test-user"
			exit 0
		fi
		if [[ "$2" == /repos/*/labels\?per_page=100 ]]; then
			printf '%s\t%s\t%s\n' \
				"status:available" "0e8a16" "Task is available for claiming" \
				"status:queued" "fbca04" "Worker dispatched, not yet started" \
				"status:claimed" "f9d0c4" "Interactive session claimed this task" \
				"status:in-progress" "1d76db" "Worker actively running" \
				"status:in-review" "5319e7" "PR open, awaiting review/merge" \
				"status:done" "6f42c1" "Task is complete" \
				"status:blocked" "d93f0b" "Waiting on blocker task"
			exit 0
		fi
		[[ "$2" == /repos/*/issues/[0-9]* ]] && exit 1
		;;
	issue)
		case "$2" in
			list)
				cat "${ISSUES_JSON_FILE}"
				exit 0
				;;
			edit) exit 0 ;;
			view) echo '{"state":"OPEN","labels":[]}'; exit 0 ;;
		esac
		;;
	label)
		exit 0
		;;
esac
exit 0
STUB
chmod +x "${STUB_DIR}/gh"

# Source the reconciler now that the stub is in place
: >"$GH_CALLS"
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/pulse-issue-reconcile.sh" >/dev/null 2>&1
set +e
export PATH="${STUB_DIR}:${PATH}"
gh_issue_list() {
	gh issue list "$@"
	return $?
}

_normalize_label_invariants "test-user" "$REPOS_JSON_FILE" >/dev/null 2>&1

# Count edit calls per issue number
count_edits_for() {
	local num="$1"
	local count
	count=$(safe_grep_count "^issue edit ${num} " "$GH_CALLS")
	count="${count//[^0-9]/}"
	echo "${count:-0}"
}

# Issue #1: dual-status → one edit (set_issue_status = one gh call)
n1=$(count_edits_for 1)
if [[ "$n1" -ge 1 ]]; then
	print_result "reconciler fixes #1 dual-status (keeps 'queued')" 0
else
	print_result "reconciler fixes #1 dual-status (keeps 'queued')" 1 "(edit calls: $n1)"
fi

# The edit for #1 must add queued and remove available
edit1=$(grep "^issue edit 1 " "$GH_CALLS" | head -1)
if [[ "$edit1" == *"--add-label status:queued"* && "$edit1" == *"--remove-label status:available"* ]]; then
	print_result "reconciler #1 survivor is 'queued' (precedence over 'available')" 0
else
	print_result "reconciler #1 survivor is 'queued' (precedence over 'available')" 1 "(line: '$edit1')"
fi

# Issue #2: done + in-review + in-progress → survivor MUST be done (terminal)
edit2=$(grep "^issue edit 2 " "$GH_CALLS" | head -1)
if [[ "$edit2" == *"--add-label status:done"* ]]; then
	print_result "reconciler #2 survivor is 'done' (terminal — wins over in-review)" 0
else
	print_result "reconciler #2 survivor is 'done' (terminal — wins over in-review)" 1 "(line: '$edit2')"
fi

# Issue #3: triple-tier → keep thinking, remove standard + simple
edit3=$(grep "^issue edit 3 " "$GH_CALLS" | head -1)
if [[ "$edit3" == *"--remove-label tier:standard"* && "$edit3" == *"--remove-label tier:simple"* &&
	"$edit3" != *"--remove-label tier:thinking"* ]]; then
	print_result "reconciler #3 keeps tier:thinking, removes tier:standard and tier:simple" 0
else
	print_result "reconciler #3 keeps tier:thinking, removes tier:standard and tier:simple" 1 "(line: '$edit3')"
fi

# Issue #4: blocked + queued → keep queued (blocked is lowest-precedence)
edit4=$(grep "^issue edit 4 " "$GH_CALLS" | head -1)
if [[ "$edit4" == *"--add-label status:queued"* && "$edit4" == *"--remove-label status:blocked"* ]]; then
	print_result "reconciler #4 survivor is 'queued' (blocked is lowest precedence)" 0
else
	print_result "reconciler #4 survivor is 'queued' (blocked is lowest precedence)" 1 "(line: '$edit4')"
fi

# Issue #5: single status → no-op (no edit call for this number)
n5=$(count_edits_for 5)
if [[ "$n5" -eq 0 ]]; then
	print_result "reconciler #5 single-label no-op" 0
else
	print_result "reconciler #5 single-label no-op" 1 "(edit calls: $n5)"
fi

# Issue #6, #7, #8, #9, #10: triage-missing count-only/non-task (no edits)
n6=$(count_edits_for 6)
n7=$(count_edits_for 7)
n8=$(count_edits_for 8)
n9=$(count_edits_for 9)
n10=$(count_edits_for 10)
if [[ "$n6" -eq 0 && "$n7" -eq 0 && "$n8" -eq 0 && "$n9" -eq 0 && "$n10" -eq 0 ]]; then
	print_result "reconciler does not auto-fix triage-missing issues" 0
else
	print_result "reconciler does not auto-fix triage-missing issues" 1 "(edits: #6=$n6 #7=$n7 #8=$n8 #9=$n9 #10=$n10)"
fi

# Issues #11/#12: null/missing labels must not make jq abort the row stream.
n11=$(count_edits_for 11)
n12=$(count_edits_for 12)
if [[ "$n11" -eq 0 && "$n12" -eq 0 ]]; then
	print_result "reconciler tolerates null and missing labels" 0
else
	print_result "reconciler tolerates null and missing labels" 1 "(edits: #11=$n11 #12=$n12)"
fi

# Already-authorized auto-dispatch work missing a tier is routable after the
# pass. This must not mutate review or explicit no-auto-dispatch safeguards.
edit13=$(grep "^issue edit 13 " "$GH_CALLS" | head -1)
if [[ "$edit13" == *"--add-label tier:standard"* && "$edit13" != *"--remove-label needs-maintainer-review"* ]]; then
	print_result "reconciler backfills a missing auto-dispatch tier without clearing review" 0
else
	print_result "reconciler backfills a missing auto-dispatch tier without clearing review" 1 "(line: '$edit13')"
fi

edit14=$(grep "^issue edit 14 " "$GH_CALLS" | head -1)
if [[ "$edit14" == *"--add-label tier:standard"* && "$edit14" != *"--remove-label no-auto-dispatch"* ]]; then
	print_result "reconciler backfills a missing tier without clearing explicit hold" 0
else
	print_result "reconciler backfills a missing tier without clearing explicit hold" 1 "(line: '$edit14')"
fi

# Counter file must be written with exact numbers
COUNTER_FILE="${HOME}/.aidevops/cache/pulse-label-invariants.$(hostname -s 2>/dev/null || echo unknown).json"
if [[ -f "$COUNTER_FILE" ]]; then
	print_result "reconciler writes counter file" 0
else
	print_result "reconciler writes counter file" 1 "(expected: $COUNTER_FILE)"
fi

if [[ -f "$COUNTER_FILE" ]]; then
	status_fixed=$(jq -r '.status_fixed' "$COUNTER_FILE" 2>/dev/null || echo 0)
	tier_fixed=$(jq -r '.tier_fixed' "$COUNTER_FILE" 2>/dev/null || echo 0)
	triage_missing=$(jq -r '.triage_missing' "$COUNTER_FILE" 2>/dev/null || echo 0)

	# status_fixed: #1, #2, #4 → 3
	if [[ "$status_fixed" -eq 3 ]]; then
		print_result "counter status_fixed=3 (issues #1, #2, #4)" 0
	else
		print_result "counter status_fixed=3 (issues #1, #2, #4)" 1 "(got: $status_fixed)"
	fi

	# tier_fixed: #3 dedup plus #13/#14 missing-tier backfill → 3
	if [[ "$tier_fixed" -eq 3 ]]; then
		print_result "counter tier_fixed=3 (issues #3, #13, #14)" 0
	else
		print_result "counter tier_fixed=3 (issues #3, #13, #14)" 1 "(got: $tier_fixed)"
	fi

	# triage_missing: #6 only (#7 is recent, #8 has a tier, #9/#10 are non-task labels)
	if [[ "$triage_missing" -eq 1 ]]; then
		print_result "counter triage_missing=1 (only #6 matches all criteria; non-task labels ignored)" 0
	else
		print_result "counter triage_missing=1 (only #6 matches all criteria; non-task labels ignored)" 1 "(got: $triage_missing)"
	fi
fi

# =============================================================================
# Part 4 — issue-sync-reusable.yml workflow atomicity guard (t2137)
# =============================================================================
# The bash helper path (_mark_issue_done) and the GitHub Actions workflow
# path (.github/workflows/issue-sync-reusable.yml `sync-on-pr-merge` job) both mutate
# status:* labels on PR merge. t2040 fixed atomicity in the bash helper but
# the workflow carried a duplicated non-atomic implementation (1 add call +
# 7 remove calls in a loop = 8 sequential API calls = ~5s race window).
# This guard parses the workflow yaml directly and asserts the status label
# mutation block uses a single `gh issue edit` call with the full flag set.
WORKFLOW_FILE="$(cd "${TEST_SCRIPTS_DIR}/../.." && pwd)/.github/workflows/issue-sync-reusable.yml"

if [[ ! -f "$WORKFLOW_FILE" ]]; then
	print_result "issue-sync-reusable.yml exists (for atomicity guard)" 1 "(not found at $WORKFLOW_FILE)"
else
	print_result "issue-sync-reusable.yml exists (for atomicity guard)" 0

	# Extract the `Apply closing hygiene to linked issues` step body — from
	# the step name to the next `- name:` line. awk handles this cleanly.
	hygiene_block=$(awk '
		/- name: Apply closing hygiene to linked issues/ { in_block=1 }
		in_block && /^      - name:/ && !/Apply closing hygiene/ { in_block=0 }
		in_block { print }
	' "$WORKFLOW_FILE")

	if [[ -z "$hygiene_block" ]]; then
		print_result "found 'Apply closing hygiene' step in workflow" 1
	else
		print_result "found 'Apply closing hygiene' step in workflow" 0

		# Count `gh issue edit` invocations inside the hygiene block. The atomic
		# implementation has exactly ONE (the status:done mutation). Any more
		# means the loop-of-remove-calls fossil has been reintroduced.
		# Note: the multi-line `gh issue edit ... \` counts as one invocation.
		edit_count=$(echo "$hygiene_block" | safe_grep_count -E '^[[:space:]]+gh issue edit[[:space:]]')
		edit_count="${edit_count//[^0-9]/}"
		edit_count="${edit_count:-0}"
		if [[ "$edit_count" -eq 1 ]]; then
			print_result "workflow status mutation is atomic (exactly 1 gh issue edit)" 0
		else
			print_result "workflow status mutation is atomic (exactly 1 gh issue edit)" 1 \
				"(got $edit_count gh issue edit invocations in hygiene block)"
		fi

		# The single invocation must add status:done and remove every sibling.
		# Check for the flags in the combined block (flags may span continuation lines).
		if echo "$hygiene_block" | grep -q -- '--add-label "status:done"'; then
			print_result "workflow hygiene adds status:done" 0
		else
			print_result "workflow hygiene adds status:done" 1
		fi

		missing_removals=""
		for sibling in status:available status:queued status:claimed \
			status:in-review status:in-progress status:blocked status:verify-failed; do
			if ! echo "$hygiene_block" | grep -q -- "--remove-label \"$sibling\""; then
				missing_removals="$missing_removals $sibling"
			fi
		done
		if [[ -z "$missing_removals" ]]; then
			print_result "workflow hygiene removes all sibling status labels" 0
		else
			print_result "workflow hygiene removes all sibling status labels" 1 \
				"(missing:$missing_removals)"
		fi

		# Non-atomic fossil detection: a `for STALE_LABEL in status:*` loop with
		# an internal `gh issue edit --remove-label` is the exact pattern that
		# caused the drift. Reject any reintroduction.
		if echo "$hygiene_block" | grep -qE 'for[[:space:]]+STALE_LABEL[[:space:]]+in[[:space:]]+"status:'; then
			print_result "workflow hygiene has no STALE_LABEL remove-loop (fossil)" 1 \
				"(the non-atomic loop pattern has been reintroduced)"
		else
			print_result "workflow hygiene has no STALE_LABEL remove-loop (fossil)" 0
		fi
	fi

	# Parent-task title-fallback guard: the `Find issue by task ID (fallback)`
	# step must probe the parent-task label and skip when present. Guards
	# against the t2137 regression where planning PRs on parent-tasks
	# incorrectly flipped the parent to status:done via title-matching.
	find_block=$(awk '
		/- name: Find issue by task ID \(fallback\)/ { in_block=1 }
		in_block && /^      - name:/ && !/Find issue by task ID/ { in_block=0 }
		in_block { print }
	' "$WORKFLOW_FILE")

	# Skip signature: either the original parent-task label probe exists, or the
	# stronger GH#23516 explicit-link gate disables title fallback entirely. In
	# both cases an `echo "found_issues="` must emit empty output to GITHUB_OUTPUT.
	if echo "$find_block" | grep -qE 'echo[[:space:]]+"found_issues="' &&
		{ echo "$find_block" | grep -qE 'parent-task' ||
			echo "$find_block" | grep -qE 'No explicit closing issue'; }; then
		print_result "find-issue step skips unsafe title-fallback matches (t2137/GH#23516)" 0
	else
		print_result "find-issue step skips unsafe title-fallback matches (t2137/GH#23516)" 1 \
			"(expected parent-task probe or explicit-link gate + empty found_issues emission)"
	fi
fi

# =============================================================================
# Part 5 — issue-sync-helper.sh::_do_close parent-task close gate (GH#20828)
# =============================================================================
# The bash-helper close path runs from TODO.md `[x]` pushes. Without a
# parent-task probe, every `[x]` for a planning task whose linked issue
# carries `parent-task` would close the parent — wiping the open-until-
# terminal-PR contract. Mirror of Part 4's t2137 workflow guard, applied to
# the parallel bash-helper code path.
HELPER_FILE="${TEST_SCRIPTS_DIR}/issue-sync-helper-close.sh"

if [[ ! -f "$HELPER_FILE" ]]; then
	print_result "issue-sync-helper.sh exists (for close-gate guard)" 1 "(not found at $HELPER_FILE)"
else
	print_result "issue-sync-helper.sh exists (for close-gate guard)" 0

	# Extract the _do_close function body. Awk handles the `name() { ... }`
	# bash idiom: from `_do_close()` to the matching closing brace.
	close_block=$(awk '/^_do_close\(\)/,/^}/' "$HELPER_FILE")

	if [[ -z "$close_block" ]]; then
		print_result "found _do_close function in issue-sync-helper.sh" 1
	else
		print_result "found _do_close function in issue-sync-helper.sh" 0

		# Skip signature: parent-task probe (gh api fetching labels) AND a
		# parent-task grep AND an early-return BEFORE the gh issue close
		# call. All three indicators together prove the skip path exists
		# and runs ahead of the close mutation.
		has_label_fetch=0
		has_parent_check=0
		guard_before_close=0

		if echo "$close_block" | grep -qE 'gh api.*labels.*name'; then
			has_label_fetch=1
		fi
		if echo "$close_block" | grep -qE 'parent-task'; then
			has_parent_check=1
		fi
		# Guard ordering: the parent-task line must precede `gh "${close_args[@]}"`
		# (the close mutation). awk emits line numbers we can compare.
		guard_line=$(echo "$close_block" | awk '/parent-task/ { print NR; exit }')
		close_line=$(echo "$close_block" | awk '/gh "\$\{close_args\[@\]\}"/ { print NR; exit }')
		if [[ -n "$guard_line" && -n "$close_line" && "$guard_line" -lt "$close_line" ]]; then
			guard_before_close=1
		fi

		if [[ "$has_label_fetch" -eq 1 && "$has_parent_check" -eq 1 && "$guard_before_close" -eq 1 ]]; then
			print_result "_do_close skips parent-task issues before gh close (GH#20828)" 0
		else
			missing=""
			[[ "$has_label_fetch" -eq 0 ]] && missing="${missing} label-fetch"
			[[ "$has_parent_check" -eq 0 ]] && missing="${missing} parent-task-grep"
			[[ "$guard_before_close" -eq 0 ]] && missing="${missing} guard-before-close-ordering"
			print_result "_do_close skips parent-task issues before gh close (GH#20828)" 1 \
				"(missing:${missing})"
		fi
	fi
fi

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
