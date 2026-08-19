#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-origin-label-mutex-create.sh — t3088 regression guard.
#
# Companion to test-origin-label-exclusion.sh (which guards EDIT-path
# sibling-removal via set_origin_label). This test guards the CREATE path:
# gh_create_pr / gh_create_issue must produce EXACTLY ONE origin label, never
# two.
#
# Failure motivating this test: marcusquinn/aidevops#21862 (PR #21825
# accumulated both origin:interactive AND origin:worker on creation because
# two independent code paths each appended a --label "origin:*" flag with
# divergent values — full-loop-helper.sh's hand-rolled headless-env check
# disagreed with detect_session_origin() in shared-gh-wrappers-session.sh).
#
# Four layers tested:
#
#   A. _gh_wrapper_args_have_origin_label — argv inspection helper used by
#      the wrapper's defence-in-depth guard (Fix 3).
#   B. gh_create_pr / gh_create_issue — wrapper self-injects origin label
#      ONLY when the caller has not already specified one (Fix 3).
#   C. full-loop-helper.sh / full-loop-helper-commit.sh — _create_pr no
#      longer passes its own --label "$origin_label" (Fix 2), and the upstream
#      origin_label computation now uses canonical session_origin_label() so
#      env-var divergence with detect_session_origin() is impossible (Fix 1).
#   D. set_origin_label — any failed GraphQL edit attempts the equivalent REST
#      mutex mutation before returning failure (GH#28029).

set -uo pipefail

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
	return 0
}

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# Mock gh that records its arguments and prints a fake URL on create.
# IMPORTANT: GH_RECORD_FILE must be exported so the gh-subshell call inside
# the wrappers (gh pr create runs in $(...) ) sees it. Without export, the
# mock writes to an empty $GH_RECORD_FILE and the recorder log silently stays
# empty — wasted hours of debugging during the canonical t3088 fix.
export GH_RECORD_FILE="${TEST_ROOT}/gh_calls.log"
MOCK_BIN_DIR="${TEST_ROOT}/mockbin"
mkdir -p "$MOCK_BIN_DIR"
cat >"${MOCK_BIN_DIR}/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_RECORD_FILE}"
if [[ -n "${GH_ARGV_RECORD_FILE:-}" ]]; then
	for arg in "$@"; do
		printf '<%s>\n' "$arg" >>"${GH_ARGV_RECORD_FILE}"
	done
fi
# pr/issue create paths print a URL on stdout for caller capture
case "$1 $2" in
"pr create" | "issue create")
	echo "https://example.invalid/o/r/pull/0"
	;;
esac
exit 0
MOCK
chmod +x "${MOCK_BIN_DIR}/gh"
export PATH="${MOCK_BIN_DIR}:${PATH}"

# Stub helpers that wrappers may invoke during create paths
mkdir -p "${MOCK_BIN_DIR}"
for stub in gh-signature-helper.sh _ensure_origin_labels_for_args; do
	:
done

# Source the wrapper library under test. shared-gh-wrappers.sh is the
# orchestrator that source-loads create + session sub-libraries.
SHARED_GH="${TEST_SCRIPTS_DIR}/shared-gh-wrappers.sh"
if [[ ! -f "$SHARED_GH" ]]; then
	echo "FAIL setup: ${SHARED_GH} not found" >&2
	exit 1
fi
# shellcheck source=/dev/null
source "$SHARED_GH" >/dev/null 2>&1 || true

# Stub _ensure_origin_labels_for_args (no-op — we don't care about label
# provisioning, only about which --label flags reach gh)
_ensure_origin_labels_for_args() { return 0; }

# Stub _gh_wrapper_auto_sig (no-op — bypasses signature footer modification
# so we don't have to plumb a fake helper path)
_gh_wrapper_auto_sig() {
	_GH_WRAPPER_SIG_MODIFIED_ARGS=("$@")
	return 0
}

# Stub _gh_validate_edit_args (always pass — body validation isn't under test)
_gh_validate_edit_args() { return 0; }

# Privacy/write-policy and durable readback have dedicated suites. This harness
# inspects only the exact create argv emitted by the wrapper.
_gh_guard_public_write_args() { return 0; }
_gh_create_pr_origin_is_exact() { return 0; }
_gh_lock_created_auto_dispatch_issue() { return 0; }

# Stub _gh_should_fallback_to_rest (never fall back — REST path adds noise)
_gh_should_fallback_to_rest() { return 1; }

# Stub _gh_auto_link_sub_issue (no-op — sub-issue linkage isn't under test)
_gh_auto_link_sub_issue() { return 0; }

# Stub _gh_wrapper_auto_assignee (returns empty so issue create takes
# the simple path — assignee logic isn't under test)
_gh_wrapper_auto_assignee() { return 0; }

# Stub TODO derivation hooks. Most tests leave these empty; B'9 sets env vars
# to simulate TODO.md-derived labels without depending on a repository TODO.md.
_gh_wrapper_extract_task_id_from_title() {
	[[ -n "${TEST_TODO_TASK_ID:-}" ]] && printf '%s' "$TEST_TODO_TASK_ID"
	return 0
}
_gh_wrapper_derive_todo_labels() {
	local task_id="$1"
	[[ -n "$task_id" && -n "${TEST_TODO_DERIVED_LABELS:-}" ]] && printf '%s' "$TEST_TODO_DERIVED_LABELS"
	return 0
}

# Stub session_origin_label so we can deterministically control what the
# wrapper would self-inject. Tests call it via env var SESSION_ORIGIN_OVERRIDE.
session_origin_label() {
	printf '%s' "${SESSION_ORIGIN_OVERRIDE:-origin:interactive}"
}
detect_session_origin() {
	case "${SESSION_ORIGIN_OVERRIDE:-origin:interactive}" in
	origin:worker) printf '%s' "worker" ;;
	origin:worker-takeover) printf '%s' "worker-takeover" ;;
	*) printf '%s' "interactive" ;;
	esac
}

reset_recorder() { : >"${GH_RECORD_FILE}"; }

count_origin_labels_in_log() {
	# Count distinct origin:* labels that would actually reach GitHub
	# from the most recent gh call. Treats comma-separated --label values
	# the same way gh does (one label per comma-segment), so
	#   --label bug,origin:worker         → 1 origin label
	#   --label origin:worker --label origin:interactive → 2
	#   --label origin:worker,origin:interactive          → 2 (would be a bug)
	local last
	last=$(tail -1 "${GH_RECORD_FILE}" 2>/dev/null || true)
	[[ -z "$last" ]] && {
		printf '0'
		return 0
	}
	# Replace commas with spaces, then tokenise on whitespace and count
	# tokens beginning with origin:.
	local normalised="${last//,/ }"
	local count=0
	# shellcheck disable=SC2206
	local tokens=($normalised)
	for tok in "${tokens[@]}"; do
		[[ "$tok" == origin:* ]] && count=$((count + 1))
	done
	printf '%d' "$count"
}

count_status_labels_in_log() {
	local last
	last=$(tail -1 "${GH_RECORD_FILE}" 2>/dev/null || true)
	[[ -z "$last" ]] && {
		printf '0'
		return 0
	}
	local normalised="${last//,/ }"
	local count=0
	# shellcheck disable=SC2206
	local tokens=($normalised)
	local tok
	for tok in "${tokens[@]}"; do
		[[ "$tok" == status:* ]] && count=$((count + 1))
	done
	printf '%d' "$count"
	return 0
}

# ---------------------------------------------------------------------------
# Layer A: _gh_wrapper_args_have_origin_label
# ---------------------------------------------------------------------------

# A1: detects --label origin:worker (space form)
if _gh_wrapper_args_have_origin_label --label "origin:worker" --title "x"; then
	print_result "A1: detects --label origin:worker (space form)" 0
else
	print_result "A1: detects --label origin:worker (space form)" 1 "expected 0, got 1"
fi

# A2: detects --label=origin:interactive (= form)
if _gh_wrapper_args_have_origin_label --title "x" --label=origin:interactive; then
	print_result "A2: detects --label=origin:interactive (= form)" 0
else
	print_result "A2: detects --label=origin:interactive (= form)" 1 "expected 0"
fi

# A3: detects origin label inside comma-separated list
if _gh_wrapper_args_have_origin_label --label "bug,auto-dispatch,origin:worker"; then
	print_result "A3: detects origin label in comma list" 0
else
	print_result "A3: detects origin label in comma list" 1 "expected 0"
fi

# A4: detects origin:worker-takeover
if _gh_wrapper_args_have_origin_label --label "origin:worker-takeover"; then
	print_result "A4: detects origin:worker-takeover" 0
else
	print_result "A4: detects origin:worker-takeover" 1 "expected 0"
fi

# A5: returns 1 when no origin label is present
if ! _gh_wrapper_args_have_origin_label --label "bug" --label "auto-dispatch" --title "x"; then
	print_result "A5: returns 1 when no origin label present" 0
else
	print_result "A5: returns 1 when no origin label present" 1 "false positive"
fi

# A6: returns 1 with no --label flags at all
if ! _gh_wrapper_args_have_origin_label --title "x" --body "y"; then
	print_result "A6: returns 1 with no --label flags" 0
else
	print_result "A6: returns 1 with no --label flags" 1 "false positive"
fi

# A7: does NOT match a label that merely contains origin: as a substring
# (defensive — we anchor on commas so labels like "no-origin:worker" don't
# false-match. They shouldn't exist, but the helper should be precise.)
if ! _gh_wrapper_args_have_origin_label --label "thing-origin:worker-no"; then
	print_result "A7: does not false-match substring" 0
else
	# Note: current implementation matches on ,origin:* with comma anchors,
	# so this test verifies the anchor logic. If this fails, the helper has
	# loosened to a substring match which would also flag legitimate non-origin
	# labels containing "origin:" as a fragment.
	print_result "A7: does not false-match substring" 1 "loose substring match"
fi

# ---------------------------------------------------------------------------
# Layer B: gh_create_pr defence-in-depth
# ---------------------------------------------------------------------------

# B1: no caller origin → wrapper injects session origin (exactly one)
reset_recorder
SESSION_ORIGIN_OVERRIDE="origin:worker" \
	gh_create_pr --repo o/r --title "t1: x" --body "Resolves #1" >/dev/null 2>&1
n=$(count_origin_labels_in_log)
if [[ "$n" == "1" ]]; then
	print_result "B1: gh_create_pr with no caller origin → exactly 1 label" 0
else
	print_result "B1: gh_create_pr with no caller origin → exactly 1 label" 1 \
		"got $n labels in: $(tail -1 "$GH_RECORD_FILE")"
fi

# B2: caller passes origin:worker → wrapper does NOT add session origin
# (would otherwise produce 2 if session is interactive)
reset_recorder
SESSION_ORIGIN_OVERRIDE="origin:interactive" \
	gh_create_pr --repo o/r --title "t1: x" --body "Resolves #1" \
	--label "origin:worker" >/dev/null 2>&1
n=$(count_origin_labels_in_log)
if [[ "$n" == "1" ]]; then
	# Also verify it's the caller's choice that won (worker, not interactive)
	last=$(tail -1 "$GH_RECORD_FILE")
	if [[ "$last" == *"origin:worker"* && "$last" != *"origin:interactive"* ]]; then
		print_result "B2: gh_create_pr respects caller origin:worker (no dup)" 0
	else
		print_result "B2: gh_create_pr respects caller origin:worker (no dup)" 1 \
			"caller intent overridden: $last"
	fi
else
	print_result "B2: gh_create_pr respects caller origin:worker (no dup)" 1 \
		"got $n labels in: $(tail -1 "$GH_RECORD_FILE")"
fi

# B3: caller passes origin:interactive while session is worker → caller wins
reset_recorder
SESSION_ORIGIN_OVERRIDE="origin:worker" \
	gh_create_pr --repo o/r --title "t1: x" --body "Resolves #1" \
	--label "origin:interactive" >/dev/null 2>&1
n=$(count_origin_labels_in_log)
if [[ "$n" == "1" ]]; then
	last=$(tail -1 "$GH_RECORD_FILE")
	if [[ "$last" == *"origin:interactive"* && "$last" != *"origin:worker"* ]]; then
		print_result "B3: gh_create_pr respects caller origin:interactive over session origin:worker" 0
	else
		print_result "B3: gh_create_pr respects caller origin:interactive over session origin:worker" 1 \
			"caller intent overridden: $last"
	fi
else
	print_result "B3: gh_create_pr respects caller origin:interactive over session origin:worker" 1 \
		"got $n labels in: $(tail -1 "$GH_RECORD_FILE")"
fi

# B4: caller passes origin in a comma-list → wrapper still skips self-injection
reset_recorder
SESSION_ORIGIN_OVERRIDE="origin:worker" \
	gh_create_pr --repo o/r --title "t1: x" --body "Resolves #1" \
	--label "bug,origin:worker" >/dev/null 2>&1
n=$(count_origin_labels_in_log)
if [[ "$n" == "1" ]]; then
	print_result "B4: gh_create_pr respects origin in comma-list (no dup)" 0
else
	print_result "B4: gh_create_pr respects origin in comma-list (no dup)" 1 \
		"got $n labels in: $(tail -1 "$GH_RECORD_FILE")"
fi

# B5: caller origin must not leave an empty argv element before gh pr create.
# Regression for GH#22022: the guarded array expansion emitted "" when
# _origin_label_args was empty, so gh failed with: unknown argument "".
reset_recorder
export GH_ARGV_RECORD_FILE="${TEST_ROOT}/gh_argv_calls.log"
: >"$GH_ARGV_RECORD_FILE"
SESSION_ORIGIN_OVERRIDE="origin:worker" \
	gh_create_pr --repo o/r --title "t1: x" --body "Resolves #1" \
	--label "origin:interactive" >/dev/null 2>&1
if grep -qx '<>' "$GH_ARGV_RECORD_FILE"; then
	print_result "B5: gh_create_pr caller origin passes no empty argv element" 1 \
		"empty argv element reached gh: $(tr '\n' ' ' <"$GH_ARGV_RECORD_FILE")"
else
	print_result "B5: gh_create_pr caller origin passes no empty argv element" 0
fi
unset GH_ARGV_RECORD_FILE

# B6: interactive gh_create_pr defaults to draft unless finalisation was explicit.
reset_recorder
export GH_ARGV_RECORD_FILE="${TEST_ROOT}/gh_argv_pr_draft_default.log"
: >"$GH_ARGV_RECORD_FILE"
SESSION_ORIGIN_OVERRIDE="origin:interactive" \
	gh_create_pr --repo o/r --title "t1: x" --body "Resolves #1" >/dev/null 2>&1
if grep -qx '<--draft>' "$GH_ARGV_RECORD_FILE"; then
	print_result "B6: gh_create_pr defaults interactive PRs to draft" 0
else
	print_result "B6: gh_create_pr defaults interactive PRs to draft" 1 \
		"--draft missing from argv: $(tr '\n' ' ' <"$GH_ARGV_RECORD_FILE")"
fi
unset GH_ARGV_RECORD_FILE

# B7: worker-origin gh_create_pr remains ready for automated worker throughput.
reset_recorder
export GH_ARGV_RECORD_FILE="${TEST_ROOT}/gh_argv_pr_worker_ready.log"
: >"$GH_ARGV_RECORD_FILE"
SESSION_ORIGIN_OVERRIDE="origin:worker" \
	gh_create_pr --repo o/r --title "t1: x" --body "Resolves #1" >/dev/null 2>&1
if grep -qx '<--draft>' "$GH_ARGV_RECORD_FILE"; then
	print_result "B7: gh_create_pr leaves worker PRs non-draft" 1 \
		"unexpected --draft in argv: $(tr '\n' ' ' <"$GH_ARGV_RECORD_FILE")"
else
	print_result "B7: gh_create_pr leaves worker PRs non-draft" 0
fi
unset GH_ARGV_RECORD_FILE

# B8: explicit finalisation preference leaves interactive PRs non-draft.
reset_recorder
export GH_ARGV_RECORD_FILE="${TEST_ROOT}/gh_argv_pr_ready_override.log"
: >"$GH_ARGV_RECORD_FILE"
AIDEVOPS_PR_CREATE_READY=1 SESSION_ORIGIN_OVERRIDE="origin:interactive" \
	gh_create_pr --repo o/r --title "t1: x" --body "Resolves #1" >/dev/null 2>&1
if grep -qx '<--draft>' "$GH_ARGV_RECORD_FILE"; then
	print_result "B8: AIDEVOPS_PR_CREATE_READY leaves interactive PR non-draft" 1 \
		"unexpected --draft in argv: $(tr '\n' ' ' <"$GH_ARGV_RECORD_FILE")"
else
	print_result "B8: AIDEVOPS_PR_CREATE_READY leaves interactive PR non-draft" 0
fi
unset AIDEVOPS_PR_CREATE_READY GH_ARGV_RECORD_FILE

# B9: conflicting caller origins are rejected before any PR create write.
reset_recorder
dual_origin_rc=0
gh_create_pr --repo o/r --title "t1: conflicting origins" --body "Resolves #1" \
	--label "origin:worker,origin:interactive" >/dev/null 2>&1 || dual_origin_rc=$?
if [[ "$dual_origin_rc" -eq 2 ]] && ! grep -q '^pr create ' "$GH_RECORD_FILE"; then
	print_result "B9: gh_create_pr rejects conflicting origins before create" 0
else
	print_result "B9: gh_create_pr rejects conflicting origins before create" 1 \
		"rc=${dual_origin_rc}; calls=$(tr '\n' ' ' <"$GH_RECORD_FILE")"
fi

# ---------------------------------------------------------------------------
# Layer B': gh_create_issue defence-in-depth (mirrors PR tests)
# ---------------------------------------------------------------------------

# B'1: no caller origin → wrapper injects session origin
reset_recorder
SESSION_ORIGIN_OVERRIDE="origin:worker" \
	gh_create_issue --repo o/r --title "t1: x" --body "y" >/dev/null 2>&1
n=$(count_origin_labels_in_log)
if [[ "$n" == "1" ]]; then
	print_result "B'1: gh_create_issue with no caller origin → exactly 1 label" 0
else
	print_result "B'1: gh_create_issue with no caller origin → exactly 1 label" 1 \
		"got $n labels in: $(tail -1 "$GH_RECORD_FILE")"
fi

# B'2: caller passes origin:worker while session is interactive → caller wins
reset_recorder
SESSION_ORIGIN_OVERRIDE="origin:interactive" \
	gh_create_issue --repo o/r --title "t1: x" --body "y" \
	--label "origin:worker" >/dev/null 2>&1
n=$(count_origin_labels_in_log)
if [[ "$n" == "1" ]]; then
	last=$(tail -1 "$GH_RECORD_FILE")
	if [[ "$last" == *"origin:worker"* && "$last" != *"origin:interactive"* ]]; then
		print_result "B'2: gh_create_issue respects caller origin:worker (no dup)" 0
	else
		print_result "B'2: gh_create_issue respects caller origin:worker (no dup)" 1 \
			"caller intent overridden: $last"
	fi
else
	print_result "B'2: gh_create_issue respects caller origin:worker (no dup)" 1 \
		"got $n labels in: $(tail -1 "$GH_RECORD_FILE")"
fi

# B'3: no TODO-derived labels + explicit non-origin labels → no empty argv element
# Regression for GH#22056: "${_todo_label_args[@]+...}" on an empty array could emit
# "" when no TODO task ID was present, causing gh CLI error:
#   unknown argument ""; please quote all values that have spaces
# Fix: use explicit ${#arr[@]} -gt 0 checks before expansion (mirrors PR #22043).
reset_recorder
export GH_ARGV_RECORD_FILE="${TEST_ROOT}/gh_argv_issue_labels.log"
: >"$GH_ARGV_RECORD_FILE"
SESSION_ORIGIN_OVERRIDE="origin:worker" \
	gh_create_issue --repo o/r --title "some title" --body "body" \
	--label "auto-dispatch" --label "tier:standard" --label "enhancement" \
	>/dev/null 2>&1
if grep -qx '<>' "$GH_ARGV_RECORD_FILE"; then
	print_result "B'3: gh_create_issue no-TODO-labels passes no empty argv element" 1 \
		"empty argv element reached gh: $(tr '\n' ' ' <"$GH_ARGV_RECORD_FILE")"
else
	print_result "B'3: gh_create_issue no-TODO-labels passes no empty argv element" 0
fi
unset GH_ARGV_RECORD_FILE

# B'4: caller passes origin label + no TODO task ID → no empty argv element
# Second regression scenario from GH#22056: both _todo_label_args AND
# _origin_label_args empty when caller provides origin label and no TODO ID.
reset_recorder
export GH_ARGV_RECORD_FILE="${TEST_ROOT}/gh_argv_issue_origin.log"
: >"$GH_ARGV_RECORD_FILE"
SESSION_ORIGIN_OVERRIDE="origin:interactive" \
	gh_create_issue --repo o/r --title "some title" --body "body" \
	--label "auto-dispatch" --label "tier:standard" --label "origin:worker" \
	>/dev/null 2>&1
if grep -qx '<>' "$GH_ARGV_RECORD_FILE"; then
	print_result "B'4: gh_create_issue caller-origin+no-TODO passes no empty argv element" 1 \
		"empty argv element reached gh: $(tr '\n' ' ' <"$GH_ARGV_RECORD_FILE")"
else
	print_result "B'4: gh_create_issue caller-origin+no-TODO passes no empty argv element" 0
fi
unset GH_ARGV_RECORD_FILE

# B'5: caller origin must not leave an empty argv element before gh issue create.
# Regression for GH#22071: the guarded array expansion emitted "" when
# _origin_label_args was empty (caller supplied origin:interactive while session
# is origin:worker), causing gh to fail with: unknown argument "".
# Mirrors B'4 with reversed session/caller origin directions.
reset_recorder
export GH_ARGV_RECORD_FILE="${TEST_ROOT}/gh_argv_issue_calls.log"
: >"$GH_ARGV_RECORD_FILE"
SESSION_ORIGIN_OVERRIDE="origin:worker" \
	gh_create_issue --repo o/r --title "t1: x" --body "Issue body" \
	--label "origin:interactive" >/dev/null 2>&1
if grep -qx '<>' "$GH_ARGV_RECORD_FILE"; then
	print_result "B'5: gh_create_issue caller origin passes no empty argv element" 1 \
		"empty argv element reached gh: $(tr '\n' ' ' <"$GH_ARGV_RECORD_FILE")"
else
	print_result "B'5: gh_create_issue caller origin passes no empty argv element" 0
fi
unset GH_ARGV_RECORD_FILE

# B'6: only --todo-task-id filtered out → no empty argv element
# Regression for shared-gh-wrappers-create.sh:203 where an empty filtered arg
# array could become a single "" argument after set --.
reset_recorder
export GH_ARGV_RECORD_FILE="${TEST_ROOT}/gh_argv_issue_todo_only.log"
: >"$GH_ARGV_RECORD_FILE"
SESSION_ORIGIN_OVERRIDE="origin:interactive" \
	gh_create_issue --todo-task-id t999 >/dev/null 2>&1
if grep -qx '<>' "$GH_ARGV_RECORD_FILE"; then
	print_result "B'6: gh_create_issue todo-only filter passes no empty argv element" 1 \
		"empty argv element reached gh: $(tr '\n' ' ' <"$GH_ARGV_RECORD_FILE")"
else
	print_result "B'6: gh_create_issue todo-only filter passes no empty argv element" 0
fi
unset GH_ARGV_RECORD_FILE

# B'7: no caller status → wrapper injects status:available with origin.
# Regression guard for pulse hygiene anomalies where gh_create_issue could
# create origin:interactive issues missing tier/auto-dispatch/status metadata.
reset_recorder
SESSION_ORIGIN_OVERRIDE="origin:interactive" \
	gh_create_issue --repo o/r --title "advisory" --body "body" >/dev/null 2>&1
status_n=$(count_status_labels_in_log)
last=$(tail -1 "$GH_RECORD_FILE")
if [[ "$status_n" == "1" && "$last" == *"status:available"* && "$last" == *"origin:interactive"* ]]; then
	print_result "B'7: gh_create_issue adds status:available with injected origin" 0
else
	print_result "B'7: gh_create_issue adds status:available with injected origin" 1 \
		"status_count=$status_n line: $last"
fi

# B'8: caller status wins — wrapper must not concatenate an extra status label.
reset_recorder
SESSION_ORIGIN_OVERRIDE="origin:interactive" \
	gh_create_issue --repo o/r --title "advisory" --body "body" \
	--label "status:blocked,origin:interactive" >/dev/null 2>&1
status_n=$(count_status_labels_in_log)
last=$(tail -1 "$GH_RECORD_FILE")
if [[ "$status_n" == "1" && "$last" == *"status:blocked"* && "$last" != *"status:available"* ]]; then
	print_result "B'8: gh_create_issue preserves caller status without concatenation" 0
else
	print_result "B'8: gh_create_issue preserves caller status without concatenation" 1 \
		"status_count=$status_n line: $last"
fi

# B'8a: explicit queued status wins — this mirrors GH#20715's test fixture.
reset_recorder
SESSION_ORIGIN_OVERRIDE="origin:interactive" \
	gh_create_issue --repo o/r --title "t2792: test-explicit-status-queued" --body "body" \
	--label "status:queued,origin:worker,auto-dispatch" >/dev/null 2>&1
status_n=$(count_status_labels_in_log)
last=$(tail -1 "$GH_RECORD_FILE")
if [[ "$status_n" == "1" && "$last" == *"status:queued"* && "$last" != *"status:available"* ]]; then
	print_result "B'8a: gh_create_issue preserves explicit status:queued" 0
else
	print_result "B'8a: gh_create_issue preserves explicit status:queued" 1 \
		"status_count=$status_n line: $last"
fi

# B'9: TODO-derived status wins — default status must inspect derived labels.
# Regression for GH#23581: gh_create_issue filtered --todo-task-id from argv,
# then checked only the filtered caller args for status labels. A status derived
# from TODO.md was appended later, so the wrapper also injected status:available.
reset_recorder
TEST_TODO_TASK_ID="t999" TEST_TODO_DERIVED_LABELS="status:queued,origin:worker" \
	SESSION_ORIGIN_OVERRIDE="origin:interactive" \
	gh_create_issue --repo o/r --title "t999: advisory" --body "body" \
	--todo-task-id t999 >/dev/null 2>&1
status_n=$(count_status_labels_in_log)
last=$(tail -1 "$GH_RECORD_FILE")
if [[ "$status_n" == "1" && "$last" == *"status:queued"* && "$last" != *"status:available"* ]]; then
	print_result "B'9: gh_create_issue preserves TODO-derived status" 0
else
	print_result "B'9: gh_create_issue preserves TODO-derived status" 1 \
		"status_count=$status_n line: $last"
fi
unset TEST_TODO_TASK_ID TEST_TODO_DERIVED_LABELS

# ---------------------------------------------------------------------------
# Layer C: structural checks on full-loop-helper-commit.sh
# ---------------------------------------------------------------------------

# C1: _create_pr no longer passes --label "$origin_label" itself
# (gh_create_pr is the single origin-label injection point)
COMMIT_HELPER="${TEST_SCRIPTS_DIR}/full-loop-helper-commit.sh"
if [[ -f "$COMMIT_HELPER" ]]; then
	# shellcheck disable=SC2016  # single-quoted regex pattern; $origin_label is literal
	if ! grep -E '^\s*local -a pr_cmd=\(.*--label "?\$origin_label"?' "$COMMIT_HELPER" >/dev/null; then
		print_result "C1: _create_pr does not pass --label \$origin_label to gh_create_pr" 0
	else
		print_result "C1: _create_pr does not pass --label \$origin_label to gh_create_pr" 1 \
			"redundant --label \$origin_label still in pr_cmd"
	fi
else
	print_result "C1: _create_pr structural check (file present)" 1 "$COMMIT_HELPER missing"
fi

# C2: full-loop-helper.sh uses session_origin_label (not a hand-rolled
# env-var check) for its origin label
LOOP_HELPER="${TEST_SCRIPTS_DIR}/full-loop-helper.sh"
if [[ -f "$LOOP_HELPER" ]]; then
	if grep -E '^\s*origin_label=\$\(session_origin_label\)' "$LOOP_HELPER" >/dev/null; then
		print_result "C2: full-loop-helper.sh uses session_origin_label() (env-var unify)" 0
	else
		print_result "C2: full-loop-helper.sh uses session_origin_label() (env-var unify)" 1 \
			"hand-rolled origin detection still present"
	fi
else
	print_result "C2: full-loop-helper.sh structural check (file present)" 1 "$LOOP_HELPER missing"
fi

# C3: full-loop-helper.sh does NOT carry the legacy hand-rolled HEADLESS check
# (anchor: a literal `if [[ "${HEADLESS:-0}" == "1"` near origin_label assignment)
if [[ -f "$LOOP_HELPER" ]]; then
	if ! grep -E '^\s*if \[\[ "\$\{HEADLESS:-0\}" == "1"' "$LOOP_HELPER" >/dev/null; then
		print_result "C3: full-loop-helper.sh has no legacy HEADLESS=1 hand-rolled check" 0
	else
		print_result "C3: full-loop-helper.sh has no legacy HEADLESS=1 hand-rolled check" 1 \
			"legacy hand-rolled check still present"
	fi
fi

# ---------------------------------------------------------------------------
# Layer D: set_origin_label REST recovery after any GraphQL edit failure
# ---------------------------------------------------------------------------

ensure_origin_labels_exist() { return 0; }
_rest_should_fallback() { return 1; }
_gh_with_timeout() {
	local operation="$1"
	shift
	printf '%s %s\n' "$operation" "$*" >>"$GH_RECORD_FILE"
	if [[ "$*" == "gh pr edit "* ]]; then
		printf 'GraphQL: Something went wrong while executing your query\n' >&2
		return 1
	fi
	return 0
}

reset_recorder
if set_origin_label 28029 owner/repo worker --pr >/dev/null 2>&1 &&
	grep -q 'gh api -X POST /repos/owner/repo/issues/28029/labels' "$GH_RECORD_FILE"; then
	print_result "D1: set_origin_label uses REST after non-rate-limit GraphQL failure" 0
else
	print_result "D1: set_origin_label uses REST after non-rate-limit GraphQL failure" 1 \
		"calls: $(tr '\n' ' ' <"$GH_RECORD_FILE")"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
