#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-interactive-session-claim.sh — t2056 regression guard.
#
# Asserts the interactive-session-helper.sh primitive behaves correctly:
#
#   1. claim writes a stamp with the expected schema
#   2. claim is idempotent (re-running refreshes timestamp, never fails)
#   3. release deletes the stamp idempotently
#   4. status lists stamps from the claim dir
#   5. status --issue returns exit 1 when the issue is not claimed
#   6. scan-stale detects dead-PID + missing-worktree claims
#   7. scan-stale ignores claims from other hostnames (can't verify)
#   8. offline gh path warns and exits 0 without blocking the caller
#   9. help subcommand prints usage
#
# The tests stub `gh`, `jq`, `kill`, and `hostname` via a PATH shim so no
# network round-trip or real process check happens. Internal functions are
# tested by sourcing the helper (the `BASH_SOURCE == "$0"` guard on main
# keeps the source call side-effect-free).

set -uo pipefail

# This suite asserts the helper's primary `gh issue edit` command shapes.
# Isolate it from pulse/runtime routing overrides inherited by worker shells.
unset AIDEVOPS_GH_FORCE_REST_READS AIDEVOPS_GH_REST_FIRST_READS _GH_SHOULD_FALLBACK_OVERRIDE

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_PATH="${TEST_SCRIPTS_DIR}/interactive-session-helper.sh"

# NOT readonly — shared-constants.sh declares readonly RED/GREEN/RESET
# and the collision under `set -e` silently kills the test shell.
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

# Sandbox HOME so the stamp dir lands inside the temp root
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace"

# -----------------------------------------------------------------------------
# PATH stub for gh — respond to auth status, user, issue view, issue edit.
# Each invocation is logged to $STUB_LOG so assertions can inspect them.
# -----------------------------------------------------------------------------
STUB_BIN="${TEST_ROOT}/stub-bin"
STUB_LOG="${TEST_ROOT}/stub-calls.log"
STUB_STATE_DIR="${TEST_ROOT}/stub-state"
mkdir -p "$STUB_BIN" "$STUB_STATE_DIR"
: >"$STUB_LOG"
# Export STUB_LOG so subprocess invocations of the stub gh see it. Without
# the export, subprocesses spawned by `"$HELPER_PATH" claim ...` inherit an
# unset STUB_LOG and the stub logs to /dev/null, making subprocess-driven
# assertions blind. Added in the GH#18786 regression coverage.
export STUB_LOG STUB_STATE_DIR

# Default stub mode — override via STUB_GH_MODE
#   online   — gh returns successful responses
#   offline  — gh auth status returns 1 (simulates offline / unauth)
export STUB_GH_MODE=online
export STUB_PERMISSION=admin

cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"${STUB_LOG:-/dev/null}"

case "$1" in
auth)
	if [[ "${STUB_GH_MODE:-online}" == "offline" ]]; then
		exit 1
	fi
	exit 0
	;;
	api)
		# Keep status transitions on their primary `gh issue edit` path. An empty
		# rate-limit response now triggers REST fallback, which this focused stub
		# does not model and would make label assertions environment-dependent.
		if [[ "$2" == "rate_limit" ]]; then
			printf '5000\n'
			exit 0
		fi
		# gh api user --jq '.login'
		if [[ "$2" == "user" ]]; then
			printf 'testuser\n'
			exit 0
		fi
		if [[ "$2" == "-i" && "${3:-}" == */collaborators/*/permission ]]; then
			if [[ "${STUB_PERMISSION_FAIL:-0}" == "1" ]]; then
				printf 'HTTP/2.0 403 Forbidden\n\n{"message":"Forbidden"}\n'
				exit 1
			fi
			printf 'HTTP/2.0 200 OK\n\n{"permission":"%s"}\n' "${STUB_PERMISSION:-admin}"
			exit 0
		fi
		if [[ "$2" == repos/*/collaborators/*/permission || "$2" == /repos/*/collaborators/*/permission ]]; then
			if [[ "${STUB_PERMISSION_FAIL:-0}" == "1" ]]; then
				exit 1
			fi
			printf '%s\n' "${STUB_PERMISSION:-admin}"
			exit 0
		fi
		exit 0
		;;
issue)
	case "$2" in
	view)
		# GH#20946 PR #20977 review: STUB_GH_VIEW_FAILS=1 simulates a gh lookup
		# failure (network, auth glitch, rate limit) so tests can exercise the
		# fail-OPEN path through `_isc_carve_out_required` rc=2 and the
		# matching `_isc_has_in_review` / `_isc_has_label` rc=2 returns.
		if [[ "${STUB_GH_VIEW_FAILS:-0}" == "1" ]]; then
			exit 1
		fi
		# GH#21805: STUB_ISSUE_STATE controls the --json state --jq .state
		# response used by the release closed-issue check. Defaults to OPEN.
		# When args include "--json state", return the state string directly.
		case "$*" in
		*"--json state --jq .state"*)
			printf '%s\n' "${STUB_ISSUE_STATE:-OPEN}"
			exit 0
			;;
		esac
		# Compose labels JSON from individual STUB_ISSUE_HAS_* flags so callers
		# can mix and match. Order does not matter; jq queries are by name.
		# - STUB_ISSUE_HAS_IN_REVIEW: status:in-review (idempotency tests)
		# - STUB_ISSUE_HAS_AUTO_DISPATCH (GH#20946): auto-dispatch
		# - STUB_ISSUE_HAS_PARENT_TASK (GH#20946): parent-task
		labels_arr=""
		if [[ "${STUB_ISSUE_HAS_IN_REVIEW:-0}" == "1" ]]; then
			labels_arr="${labels_arr:+$labels_arr,}{\"name\":\"status:in-review\"}"
		fi
		if [[ "${STUB_ISSUE_HAS_AUTO_DISPATCH:-0}" == "1" ]]; then
			labels_arr="${labels_arr:+$labels_arr,}{\"name\":\"auto-dispatch\"}"
		fi
		if [[ "${STUB_ISSUE_HAS_PARENT_TASK:-0}" == "1" ]]; then
			labels_arr="${labels_arr:+$labels_arr,}{\"name\":\"parent-task\"}"
		fi
		if [[ "$*" == *"--json state,labels,assignees,comments"* ]]; then
			state_file="${STUB_STATE_DIR:?}/${3}.json"
			if [[ -f "$state_file" ]]; then
				cat "$state_file"
				exit 0
			fi
			assignees_json=""
			assignees_csv="${STUB_ISSUE_ASSIGNEES:-testuser}"
			while IFS= read -r assignee; do
				[[ -n "$assignee" ]] && assignees_json="${assignees_json:+$assignees_json,}{\"login\":\"${assignee}\"}"
			done < <(printf '%s' "$assignees_csv" | tr ',' '\n')
			comments_json=""
			if [[ -n "${STUB_INTERACTIVE_CLAIM_USER:-}" ]]; then
				claim_time="${STUB_INTERACTIVE_CLAIM_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
				comments_json="{\"author\":{\"login\":\"${STUB_INTERACTIVE_CLAIM_USER}\"},\"createdAt\":\"${claim_time}\",\"body\":\"> Interactive session claimed by @${STUB_INTERACTIVE_CLAIM_USER} on test-host.\"}"
			fi
			printf '{"state":"%s","labels":[%s],"assignees":[%s],"comments":[%s]}\n' \
				"${STUB_ISSUE_STATE:-OPEN}" "$labels_arr" "$assignees_json" "$comments_json"
			exit 0
		fi
		printf '{"labels":[%s]}\n' "$labels_arr"
		exit 0
		;;
	edit)
		# Log the edit flags (already captured in STUB_LOG above).
		if [[ "${STUB_GH_EDIT_FAILS:-0}" == "1" ]]; then
			printf 'simulated issue edit failure\n' >&2
			exit 1
		fi
		if [[ -n "${STUB_STATE_DIR:-}" && "${STUB_GH_EDIT_NO_MUTATE:-0}" != "1" ]]; then
			new_assignee=""
			previous=""
			for argument in "$@"; do
				if [[ "$previous" == "--add-assignee" ]]; then
					new_assignee="$argument"
					break
				fi
				previous="$argument"
			done
			if [[ -n "$new_assignee" ]]; then
				printf '{"state":"OPEN","labels":[{"name":"status:in-review"}],"assignees":[{"login":"%s"}],"comments":[]}\n' \
					"$new_assignee" >"${STUB_STATE_DIR}/${3}.json"
			fi
		fi
		exit 0
		;;
	list)
		# t2148: emit a configurable JSON array for `gh issue list` calls.
		# STUB_ISSUE_LIST_JSON is the verbatim payload to print; default to
		# empty array so unrelated callers don't pick up unexpected issues.
		printf '%s\n' "${STUB_ISSUE_LIST_JSON:-[]}"
		exit 0
		;;
	esac
	exit 0
	;;
label)
	# `gh label create ... --force` — succeed silently
	exit 0
	;;
esac
exit 0
STUB
chmod +x "${STUB_BIN}/gh"

# jq is used by the helper for stamp creation and label parsing. We let the
# real jq through (it's a framework dependency) — only gh needs stubbing.
export PATH="${STUB_BIN}:${PATH}"

# Verify the stub wins the PATH lookup
if [[ "$(command -v gh)" != "${STUB_BIN}/gh" ]]; then
	printf '%sFATAL%s PATH stub not winning — tests invalid\n' "$TEST_RED" "$TEST_RESET"
	exit 1
fi

# -----------------------------------------------------------------------------
# Source the helper so internal functions are callable.
# -----------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$HELPER_PATH" >/dev/null 2>&1
# Helper sets `set -euo pipefail` — drop -e for negative assertions
set +e

# Persisted runtime cooldowns must not suppress the stubbed write calls this
# isolated command-shape suite asserts.
_gh_secondary_cooldown_preflight() {
	return 0
}

# Sanity check — did sourcing expose the functions we need?
if ! declare -f _isc_cmd_claim >/dev/null; then
	printf '%sFATAL%s _isc_cmd_claim not exposed — helper not sourceable\n' "$TEST_RED" "$TEST_RESET"
	exit 1
fi

# =============================================================================
# Test 1 — claim writes a stamp with the expected schema
# =============================================================================
export STUB_ISSUE_HAS_IN_REVIEW=0
_isc_cmd_claim 18738 testowner/testrepo --worktree /tmp/wt-fake >/dev/null 2>&1
claim_rc=$?

STAMP_FILE="${HOME}/.aidevops/.agent-workspace/interactive-claims/testowner-testrepo-18738.json"
if [[ $claim_rc -eq 0 && -f "$STAMP_FILE" ]]; then
	print_result "claim writes stamp file" 0
else
	print_result "claim writes stamp file" 1 "(rc=$claim_rc, stamp=$STAMP_FILE exists=$([[ -f "$STAMP_FILE" ]] && echo yes || echo no))"
fi

# Validate stamp schema
if [[ -f "$STAMP_FILE" ]]; then
	stamp_issue=$(jq -r '.issue' "$STAMP_FILE" 2>/dev/null)
	stamp_slug=$(jq -r '.slug' "$STAMP_FILE" 2>/dev/null)
	stamp_user=$(jq -r '.user' "$STAMP_FILE" 2>/dev/null)
	stamp_worktree=$(jq -r '.worktree_path' "$STAMP_FILE" 2>/dev/null)

	if [[ "$stamp_issue" == "18738" && "$stamp_slug" == "testowner/testrepo" && "$stamp_user" == "testuser" && "$stamp_worktree" == "/tmp/wt-fake" ]]; then
		print_result "claim stamp schema populated" 0
	else
		print_result "claim stamp schema populated" 1 "(issue=$stamp_issue slug=$stamp_slug user=$stamp_user wt=$stamp_worktree)"
	fi
fi

# =============================================================================
# Test 2 — claim is idempotent (second call refreshes, never fails)
# =============================================================================
# Flip the stub so view returns in-review — simulates already-claimed state
export STUB_ISSUE_HAS_IN_REVIEW=1
sleep 1 # ensure timestamp delta is visible
_isc_cmd_claim 18738 testowner/testrepo --worktree /tmp/wt-fake >/dev/null 2>&1
claim2_rc=$?

if [[ $claim2_rc -eq 0 && -f "$STAMP_FILE" ]]; then
	print_result "claim idempotent on re-call" 0
else
	print_result "claim idempotent on re-call" 1 "(rc=$claim2_rc)"
fi

# An initial pathless refresh must not erase the verified worktree from the
# existing stamp. This is the first half of every repeated issue-start call.
_isc_cmd_claim 18738 testowner/testrepo --implementing --defer-comment >/dev/null 2>&1
preserved_worktree=$(jq -r '.worktree_path // empty' "$STAMP_FILE" 2>/dev/null)
if [[ "$preserved_worktree" == "/tmp/wt-fake" ]]; then
	print_result "pathless idempotent claim preserves verified worktree" 0
else
	print_result "pathless idempotent claim preserves verified worktree" 1 "(worktree=$preserved_worktree)"
fi

# Canonical-rooted interactive start defers its one audit comment until the
# second claim supplies the linked worktree. Repeating both phases remains
# idempotent and does not add another ownership comment.
: >"$STUB_LOG"
STAGED_STAMP_FILE="${HOME}/.aidevops/.agent-workspace/interactive-claims/testowner-testrepo-18739.json"
export STUB_ISSUE_HAS_IN_REVIEW=0
_isc_cmd_claim 18739 testowner/testrepo --implementing --defer-comment >/dev/null 2>&1
export STUB_ISSUE_HAS_IN_REVIEW=1
_isc_cmd_claim 18739 testowner/testrepo --implementing --worktree /tmp/wt-linked >/dev/null 2>&1
_isc_cmd_claim 18739 testowner/testrepo --implementing --defer-comment >/dev/null 2>&1
_isc_cmd_claim 18739 testowner/testrepo --implementing --worktree /tmp/wt-linked >/dev/null 2>&1
staged_comment_count=$(grep -c '^gh issue comment ' "$STUB_LOG" 2>/dev/null || true)
staged_worktree=$(jq -r '.worktree_path // empty' "$STAGED_STAMP_FILE" 2>/dev/null)
if [[ "$staged_comment_count" == "1" && "$staged_worktree" == "/tmp/wt-linked" ]]; then
	print_result "deferred worktree claim posts one idempotent ownership comment" 0
else
	print_result "deferred worktree claim posts one idempotent ownership comment" 1 \
		"(comments=$staged_comment_count worktree=$staged_worktree)"
fi
_isc_delete_stamp 18739 testowner/testrepo

# =============================================================================
# Test 3 — release deletes the stamp
# =============================================================================
export STUB_ISSUE_HAS_IN_REVIEW=1
_isc_cmd_release 18738 testowner/testrepo >/dev/null 2>&1
release_rc=$?

if [[ $release_rc -eq 0 && ! -f "$STAMP_FILE" ]]; then
	print_result "release deletes stamp" 0
else
	print_result "release deletes stamp" 1 "(rc=$release_rc, stamp exists=$([[ -f "$STAMP_FILE" ]] && echo yes || echo no))"
fi

# =============================================================================
# Test 4 — release without prior claim is a no-op (idempotent)
# =============================================================================
export STUB_ISSUE_HAS_IN_REVIEW=0
_isc_cmd_release 99999 testowner/testrepo >/dev/null 2>&1
release2_rc=$?

if [[ $release2_rc -eq 0 ]]; then
	print_result "release idempotent on unclaimed issue" 0
else
	print_result "release idempotent on unclaimed issue" 1 "(rc=$release2_rc)"
fi

# =============================================================================
# Test 5 — status lists active claims
# =============================================================================
# Re-claim to populate a stamp
export STUB_ISSUE_HAS_IN_REVIEW=0
_isc_cmd_claim 18738 testowner/testrepo --worktree /tmp/wt-fake >/dev/null 2>&1
_isc_cmd_claim 18739 testowner/testrepo --worktree /tmp/wt-fake >/dev/null 2>&1

status_out=$(_isc_cmd_status 2>&1)
status_rc=$?

if [[ $status_rc -eq 0 ]] && printf '%s' "$status_out" | grep -q '#18738' && printf '%s' "$status_out" | grep -q '#18739'; then
	print_result "status lists active claims" 0
else
	print_result "status lists active claims" 1 "(rc=$status_rc, out=${status_out:0:100})"
fi

# =============================================================================
# Test 6 — scan-stale detects dead-PID + missing-worktree claims
# =============================================================================
# Forge a stamp with PID 1 (process exists) but missing worktree — should NOT
# be flagged (PID alive). Then forge a stamp with PID 999999 (dead) and
# missing worktree — SHOULD be flagged.

claim_dir="${HOME}/.aidevops/.agent-workspace/interactive-claims"
current_host=$(hostname 2>/dev/null || echo "unknown")

# Stamp A: dead PID + missing worktree + current host → stale
jq -n --arg host "$current_host" '{
	issue: 77701,
	slug: "stale/test",
	worktree_path: "/tmp/definitely-does-not-exist-77701",
	claimed_at: "2020-01-01T00:00:00Z",
	pid: 999999,
	hostname: $host,
	user: "testuser"
}' >"${claim_dir}/stale-test-77701.json"

# Stamp B: cross-host → ignored
jq -n '{
	issue: 77702,
	slug: "stale/test",
	worktree_path: "/tmp/missing-77702",
	claimed_at: "2020-01-01T00:00:00Z",
	pid: 999998,
	hostname: "not-this-host-at-all",
	user: "testuser"
}' >"${claim_dir}/stale-test-77702.json"

scan_out=$(_isc_cmd_scan_stale --no-auto-release 2>&1)
scan_rc=$?

if [[ $scan_rc -eq 0 ]] && printf '%s' "$scan_out" | grep -q '#77701' && ! printf '%s' "$scan_out" | grep -q '#77702'; then
	print_result "scan-stale flags dead-PID + missing-worktree, ignores cross-host" 0
else
	print_result "scan-stale flags dead-PID + missing-worktree, ignores cross-host" 1 "(rc=$scan_rc, out=${scan_out:0:200})"
fi

# =============================================================================
# Test 7 — offline gh path: claim warns and exits 0, no stamp written
# =============================================================================
export STUB_GH_MODE=offline
rm -f "${claim_dir}"/*.json 2>/dev/null || true

offline_out=$(_isc_cmd_claim 88888 offline/repo 2>&1)
offline_rc=$?

offline_stamp="${claim_dir}/offline-repo-88888.json"

if [[ $offline_rc -eq 0 && ! -f "$offline_stamp" ]] && printf '%s' "$offline_out" | grep -q 'offline'; then
	print_result "offline gh: warn and continue, no stamp" 0
else
	print_result "offline gh: warn and continue, no stamp" 1 "(rc=$offline_rc, out=${offline_out:0:100})"
fi

export STUB_GH_MODE=online

# =============================================================================
# Test 8 — help subcommand
# =============================================================================
help_out=$(_isc_cmd_help 2>&1)
if printf '%s' "$help_out" | grep -q 'interactive-session-helper.sh'; then
	print_result "help prints usage" 0
else
	print_result "help prints usage" 1
fi

# =============================================================================
# Test 9 — status on unknown issue returns exit 1
# =============================================================================
_isc_cmd_status 99999 >/dev/null 2>&1
st_rc=$?
if [[ $st_rc -eq 1 ]]; then
	print_result "status <unknown> returns exit 1" 0
else
	print_result "status <unknown> returns exit 1" 1 "(rc=$st_rc, expected 1)"
fi

# =============================================================================
# Test 10 — missing arguments return exit 2
# =============================================================================
_isc_cmd_claim 2>/dev/null
no_args_rc=$?
if [[ $no_args_rc -eq 2 ]]; then
	print_result "claim without args returns exit 2" 0
else
	print_result "claim without args returns exit 2" 1 "(rc=$no_args_rc, expected 2)"
fi

_isc_cmd_claim "notanumber" testowner/repo 2>/dev/null
bad_issue_rc=$?
if [[ $bad_issue_rc -eq 2 ]]; then
	print_result "claim with non-numeric issue returns exit 2" 0
else
	print_result "claim with non-numeric issue returns exit 2" 1 "(rc=$bad_issue_rc, expected 2)"
fi

# =============================================================================
# Test 11 — GH#18786 regression: claim must reach the label-apply branch
# under the script's own `set -euo pipefail` when the label is absent.
#
# The reported bug was that a bare `_isc_has_in_review` call followed by
# `has_rc=$?` capture killed _isc_cmd_claim before it could apply the
# label — because `set -e` propagates unchecked non-zero returns out of
# the parent function immediately, so `has_rc=$?` never runs. The other
# tests in this file source the helper and run with `set +e`, which masks
# this class entirely. This test EXECUTES the helper as a subprocess so
# the script's `set -euo pipefail` at line 42 is live.
#
# A second latent bug was a broken `jq -e 'any(.name; ...)'` query in
# _isc_has_in_review that raised "Cannot index array with string 'name'"
# on jq 1.7+, swallowed by `2>&1 /dev/null`, and caused the function to
# always report "label absent" — masking the set -e bug from Test 2's
# idempotency assertion (which runs under set +e in source mode).
#
# A third latent bug was `"${extra_flags[@]}"` under bash 3.2 set -u,
# previously unreachable because of the broken jq query.
#
# This regression test covers all three by asserting that:
#   (a) The subprocess exits 0 (set -e did not kill it mid-flight)
#   (b) `gh issue edit` was called with --add-label status:in-review
#       (i.e. the label-apply branch actually ran)
#   (c) A stamp file landed (end-of-claim side effect ran)
#   (d) The idempotent path (label present) exits 0 AND hits the
#       "already has status:in-review" info message without calling
#       `gh issue edit` (no transition spam on repeat claims)
#
# Reference: GH#18786, reference/bash-compat.md checklist item 4, sibling
# set -e bug class GH#18770 and GH#18784.
# =============================================================================

# Reset stamp dir for a clean run
rm -f "${claim_dir}"/*.json 2>/dev/null || true
: >"$STUB_LOG"

# --- Case (a-c): label absent, subprocess exit must be 0 with label applied ---
STUB_ISSUE_HAS_IN_REVIEW=0 STUB_GH_MODE=online \
	"$HELPER_PATH" claim 56001 regress/test --worktree /tmp/regress-wt \
	>/dev/null 2>&1
subprocess_rc=$?

regress_stamp="${claim_dir}/regress-test-56001.json"
if [[ $subprocess_rc -eq 0 && -f "$regress_stamp" ]]; then
	print_result "GH#18786: claim subprocess exits 0 under set -euo pipefail" 0
else
	print_result "GH#18786: claim subprocess exits 0 under set -euo pipefail" 1 \
		"(rc=$subprocess_rc, stamp exists=$([[ -f "$regress_stamp" ]] && echo yes || echo no))"
fi

# Verify the label-apply branch actually ran (gh issue edit was called with
# the add-label flag). This closes the test gap where Test 1 only checks the
# stamp, not whether the label transition API call happened.
if grep -q 'issue edit 56001' "$STUB_LOG" && grep -q 'add-label status:in-review' "$STUB_LOG"; then
	print_result "GH#18786: claim applies status:in-review when absent" 0
else
	print_result "GH#18786: claim applies status:in-review when absent" 1 \
		"(stub log: $(tr '\n' '|' <"$STUB_LOG"))"
fi

# --- Case (d): idempotent path — label already present, no transition ---
rm -f "${claim_dir}"/*.json 2>/dev/null || true
: >"$STUB_LOG"

idempotent_out=$(STUB_ISSUE_HAS_IN_REVIEW=1 STUB_GH_MODE=online \
	"$HELPER_PATH" claim 56001 regress/test --worktree /tmp/regress-wt \
	2>&1)
idempotent_rc=$?

if [[ $idempotent_rc -eq 0 ]] && printf '%s' "$idempotent_out" | grep -q 'already belongs to testuser'; then
	print_result "GH#18786: claim idempotent when label already present (subprocess)" 0
else
	print_result "GH#18786: claim idempotent when label already present (subprocess)" 1 \
		"(rc=$idempotent_rc, out=${idempotent_out:0:200})"
fi

# Idempotent path MUST NOT call gh issue edit (saves an API round-trip and
# prevents spurious label-change noise on every re-claim).
if ! grep -q 'issue edit' "$STUB_LOG"; then
	print_result "GH#18786: idempotent claim skips gh issue edit" 0
else
	print_result "GH#18786: idempotent claim skips gh issue edit" 1 \
		"(stub log: $(tr '\n' '|' <"$STUB_LOG"))"
fi

# --- Case (d2): explicit worker takeover replaces and verifies ownership ---
rm -f "${claim_dir}"/*.json 2>/dev/null || true
: >"$STUB_LOG"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"status:in-review"},{"name":"origin:worker"}],"assignees":[{"login":"worker-runner"}],"comments":[]}' \
	>"${STUB_STATE_DIR}/56004.json"

takeover_out=$("$HELPER_PATH" claim 56004 regress/test --implementing --worktree /tmp/takeover-wt 2>&1)
takeover_rc=$?
takeover_stamp="${claim_dir}/regress-test-56004.json"
takeover_owner=$(jq -r '.assignees | map(.login) | join(",")' "${STUB_STATE_DIR}/56004.json")
if [[ $takeover_rc -eq 0 && "$takeover_owner" == "testuser" && -f "$takeover_stamp" ]] &&
	grep -q 'remove-assignee worker-runner' "$STUB_LOG" &&
	grep -q 'add-assignee testuser' "$STUB_LOG"; then
	print_result "foreign worker claim transfers to verified interactive owner" 0
else
	print_result "foreign worker claim transfers to verified interactive owner" 1 \
		"(rc=$takeover_rc owner=$takeover_owner stamp=$([[ -f "$takeover_stamp" ]] && echo yes || echo no) log=$(tr '\n' '|' <"$STUB_LOG") out=${takeover_out:0:120})"
fi

# --- Case (d3): a recent compatible foreign interactive claim is protected ---
rm -f "${claim_dir}"/*.json 2>/dev/null || true
: >"$STUB_LOG"
claim_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"state":"OPEN","labels":[{"name":"status:in-review"}],"assignees":[{"login":"other-human"}],"comments":[{"author":{"login":"other-human"},"createdAt":"%s","body":"> Interactive session claimed by @other-human on other-host."}]}\n' \
	"$claim_now" >"${STUB_STATE_DIR}/56005.json"

foreign_out=$("$HELPER_PATH" claim 56005 regress/test --implementing --worktree /tmp/foreign-wt 2>&1)
foreign_rc=$?
foreign_stamp="${claim_dir}/regress-test-56005.json"
if [[ $foreign_rc -eq 1 && ! -f "$foreign_stamp" ]] &&
	! grep -q 'issue edit 56005' "$STUB_LOG" &&
	printf '%s' "$foreign_out" | grep -q 'live interactive owner @other-human'; then
	print_result "live foreign interactive claim is never stolen" 0
else
	print_result "live foreign interactive claim is never stolen" 1 \
		"(rc=$foreign_rc stamp=$([[ -f "$foreign_stamp" ]] && echo yes || echo no) out=${foreign_out:0:160})"
fi

# --- Case (d4): a transition that cannot be verified writes no stamp ---
rm -f "${claim_dir}"/*.json 2>/dev/null || true
: >"$STUB_LOG"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"status:in-review"}],"assignees":[{"login":"worker-runner"}],"comments":[]}' \
	>"${STUB_STATE_DIR}/56006.json"
unverified_out=$(STUB_GH_EDIT_NO_MUTATE=1 "$HELPER_PATH" claim 56006 regress/test --implementing 2>&1)
unverified_rc=$?
unverified_stamp="${claim_dir}/regress-test-56006.json"
if [[ $unverified_rc -eq 1 && ! -f "$unverified_stamp" ]] &&
	printf '%s' "$unverified_out" | grep -q 'could not be verified'; then
	print_result "unverified worker takeover writes no stamp" 0
else
	print_result "unverified worker takeover writes no stamp" 1 \
		"(rc=$unverified_rc stamp=$([[ -f "$unverified_stamp" ]] && echo yes || echo no) out=${unverified_out:0:160})"
fi

# --- Case (e): release subprocess also survives set -euo pipefail ---
rm -f "${claim_dir}"/*.json 2>/dev/null || true
: >"$STUB_LOG"

# Pre-populate a stamp so release has something to delete
STUB_ISSUE_HAS_IN_REVIEW=0 "$HELPER_PATH" claim 56002 regress/test >/dev/null 2>&1

release_sub_rc=0
STUB_ISSUE_HAS_IN_REVIEW=1 "$HELPER_PATH" release 56002 regress/test >/dev/null 2>&1 || release_sub_rc=$?
release_stamp="${claim_dir}/regress-test-56002.json"

if [[ $release_sub_rc -eq 0 && ! -f "$release_stamp" ]]; then
	print_result "GH#18786: release subprocess exits 0 under set -euo pipefail" 0
else
	print_result "GH#18786: release subprocess exits 0 under set -euo pipefail" 1 \
		"(rc=$release_sub_rc, stamp exists=$([[ -f "$release_stamp" ]] && echo yes || echo no))"
fi

# --- Case (f): _isc_has_in_review jq query is not broken (dead-code gate) ---
# The previous `any(.name; ...)` form raised "Cannot index array with string".
# Assert the repaired query correctly distinguishes present from absent and
# from lookup-failure by driving _isc_has_in_review directly with stub modes.
export STUB_ISSUE_HAS_IN_REVIEW=1
_isc_has_in_review 56003 regress/test
jq_present_rc=$?

export STUB_ISSUE_HAS_IN_REVIEW=0
_isc_has_in_review 56003 regress/test
jq_absent_rc=$?

if [[ $jq_present_rc -eq 0 && $jq_absent_rc -eq 1 ]]; then
	print_result "GH#18786: _isc_has_in_review jq query returns 0/1 correctly" 0
else
	print_result "GH#18786: _isc_has_in_review jq query returns 0/1 correctly" 1 \
		"(present_rc=$jq_present_rc, absent_rc=$jq_absent_rc, expected 0/1)"
fi

# =============================================================================
# Test 12 — t2148: _isc_list_stampless_interactive_claims detects the zombie
# claim state (origin:interactive + assignee + no stamp)
# =============================================================================
# Clean slate — no stamps in the dir
rm -f "${claim_dir}"/*.json 2>/dev/null || true

# Stub `gh issue list` to return two origin:interactive + assigned issues
export STUB_ISSUE_LIST_JSON='[
  {"number": 91001, "updatedAt": "2025-01-01T00:00:00Z", "labels": []},
  {"number": 91002, "updatedAt": "2025-01-01T00:00:00Z", "labels": []}
]'

stampless_rows=$(_isc_list_stampless_interactive_claims testuser stamp/test 2>&1)
stampless_rc=$?

# Both should be listed (no stamps exist)
if [[ $stampless_rc -eq 0 ]] &&
	printf '%s' "$stampless_rows" | grep -q '"number":91001' &&
	printf '%s' "$stampless_rows" | grep -q '"number":91002'; then
	print_result "t2148: stampless primitive detects zombie claims (positive case)" 0
else
	print_result "t2148: stampless primitive detects zombie claims (positive case)" 1 \
		"(rc=$stampless_rc, rows=${stampless_rows:0:200})"
fi

# =============================================================================
# Test 13 — t2148: stampless primitive ignores issues with an existing stamp
# =============================================================================
# Write a stamp for 91001 — it must be excluded from the output
jq -n '{
	issue: 91001, slug: "stamp/test", worktree_path: "/tmp/x",
	claimed_at: "2026-01-01T00:00:00Z", pid: 1, hostname: "h", user: "testuser"
}' >"${claim_dir}/stamp-test-91001.json"

stampless_rows2=$(_isc_list_stampless_interactive_claims testuser stamp/test 2>&1)
stampless_rc2=$?

# 91001 should be excluded (stamp present); 91002 should still be listed
if [[ $stampless_rc2 -eq 0 ]] &&
	! printf '%s' "$stampless_rows2" | grep -q '"number":91001' &&
	printf '%s' "$stampless_rows2" | grep -q '"number":91002'; then
	print_result "t2148: stampless primitive excludes stamped claims (negative case)" 0
else
	print_result "t2148: stampless primitive excludes stamped claims (negative case)" 1 \
		"(rc=$stampless_rc2, rows=${stampless_rows2:0:200})"
fi

# =============================================================================
# Test 14 — t2148: scan-stale Phase 1a surfaces stampless claims
# =============================================================================
# Populate a minimal repos.json so the Phase 1a loop has a repo to iterate.
# Clean the stamp and let the stub re-emit both issues.
rm -f "${claim_dir}/stamp-test-91001.json" 2>/dev/null || true
repos_json="${HOME}/.config/aidevops/repos.json"
mkdir -p "$(dirname "$repos_json")"
jq -n '{
	initialized_repos: [
		{slug: "stamp/test", pulse: true, local_only: false}
	]
}' >"$repos_json"

scan_out_1a=$(_isc_cmd_scan_stale 2>&1)
scan_rc_1a=$?

if [[ $scan_rc_1a -eq 0 ]] &&
	printf '%s' "$scan_out_1a" | grep -q 'Stampless interactive claims' &&
	printf '%s' "$scan_out_1a" | grep -q '#91001 in stamp/test'; then
	print_result "t2148: scan-stale Phase 1a surfaces stampless claims" 0
else
	print_result "t2148: scan-stale Phase 1a surfaces stampless claims" 1 \
		"(rc=$scan_rc_1a, out=$(printf '%s' "$scan_out_1a" | tr '\n' '|' | head -c 400))"
fi

# Reset to avoid polluting later tests if any are added below
export STUB_ISSUE_LIST_JSON='[]'
rm -f "$repos_json" 2>/dev/null || true

# =============================================================================
# Test 15 — GH#20946: auto-dispatch carve-out without --implementing
#
# `_isc_cmd_claim` MUST refuse to claim issues tagged `auto-dispatch` when
# `--implementing` is not passed and the issue is not also tagged
# `parent-task`. Without this guard, claim creates the
# (origin:interactive + assignee + status:in-review) combination that
# `_has_active_claim` in dispatch-dedup-helper.sh treats as an active claim,
# permanently blocking pulse dispatch (t1996/GH#18352). The three creation-
# time guards (t2218, t2132, t2157/t2406) skip self-assign at creation; this
# probe extends the same invariant to the manual claim subcommand.
#
# Subprocess form so the script's own `set -euo pipefail` is live (mirrors
# the GH#18786 regression-coverage approach).
# =============================================================================
rm -f "${claim_dir}"/*.json 2>/dev/null || true
: >"$STUB_LOG"

ad_skip_out=$(STUB_ISSUE_HAS_IN_REVIEW=0 STUB_ISSUE_HAS_AUTO_DISPATCH=1 STUB_ISSUE_HAS_PARENT_TASK=0 STUB_GH_MODE=online \
	"$HELPER_PATH" claim 60001 carveout/test --worktree /tmp/carveout-wt 2>&1)
ad_skip_rc=$?

ad_skip_stamp="${claim_dir}/carveout-test-60001.json"

# Subprocess MUST exit 0, MUST warn about auto-dispatch, MUST NOT call
# `gh issue edit` (no transition, no self-assign), MUST NOT write a stamp.
if [[ $ad_skip_rc -eq 0 && ! -f "$ad_skip_stamp" ]] &&
	printf '%s' "$ad_skip_out" | grep -q 'auto-dispatch' &&
	! grep -q 'issue edit 60001' "$STUB_LOG"; then
	print_result "GH#20946: auto-dispatch claim without --implementing skips" 0
else
	print_result "GH#20946: auto-dispatch claim without --implementing skips" 1 \
		"(rc=$ad_skip_rc, stamp=$([[ -f "$ad_skip_stamp" ]] && echo yes || echo no), gh-edit=$(grep -q 'issue edit 60001' "$STUB_LOG" && echo yes || echo no), out=${ad_skip_out:0:200})"
fi

# =============================================================================
# Test 16 — GH#20946: --implementing flag bypasses the carve-out
#
# When the agent legitimately intends to implement an auto-dispatch issue
# itself (per the AGENTS.md "Implementing a #auto-dispatch task interactively"
# mandate), `--implementing` must bypass the probe and apply the claim
# normally — gh issue edit called, status:in-review label added, stamp
# written.
# =============================================================================
rm -f "${claim_dir}"/*.json 2>/dev/null || true
: >"$STUB_LOG"

ad_impl_out=$(STUB_ISSUE_HAS_IN_REVIEW=0 STUB_ISSUE_HAS_AUTO_DISPATCH=1 STUB_ISSUE_HAS_PARENT_TASK=0 STUB_GH_MODE=online \
	"$HELPER_PATH" claim 60002 carveout/test --worktree /tmp/carveout-wt --implementing 2>&1)
ad_impl_rc=$?

ad_impl_stamp="${claim_dir}/carveout-test-60002.json"

if [[ $ad_impl_rc -eq 0 && -f "$ad_impl_stamp" ]] &&
	grep -q 'issue edit 60002' "$STUB_LOG" &&
	grep -q 'add-label status:in-review' "$STUB_LOG"; then
	print_result "GH#20946: auto-dispatch claim WITH --implementing proceeds" 0
else
	print_result "GH#20946: auto-dispatch claim WITH --implementing proceeds" 1 \
		"(rc=$ad_impl_rc, stamp=$([[ -f "$ad_impl_stamp" ]] && echo yes || echo no), out=${ad_impl_out:0:200})"
fi

# =============================================================================
# Test 17 — GH#20946: parent-task carve-out (auto-dispatch + parent-task → claim)
#
# parent-task issues are decomposition trackers the maintainer needs to own.
# They already block pulse dispatch via `PARENT_TASK_BLOCKED` upstream of the
# auto-dispatch path, so claiming them is safe — no `--implementing` flag
# required. Validates that the probe correctly distinguishes the two label
# combinations.
# =============================================================================
rm -f "${claim_dir}"/*.json 2>/dev/null || true
: >"$STUB_LOG"

ad_pt_out=$(STUB_ISSUE_HAS_IN_REVIEW=0 STUB_ISSUE_HAS_AUTO_DISPATCH=1 STUB_ISSUE_HAS_PARENT_TASK=1 STUB_GH_MODE=online \
	"$HELPER_PATH" claim 60003 carveout/test --worktree /tmp/carveout-wt 2>&1)
ad_pt_rc=$?

ad_pt_stamp="${claim_dir}/carveout-test-60003.json"

if [[ $ad_pt_rc -eq 0 && -f "$ad_pt_stamp" ]] &&
	grep -q 'issue edit 60003' "$STUB_LOG" &&
	grep -q 'add-label status:in-review' "$STUB_LOG"; then
	print_result "GH#20946: auto-dispatch + parent-task claim proceeds (no flag)" 0
else
	print_result "GH#20946: auto-dispatch + parent-task claim proceeds (no flag)" 1 \
		"(rc=$ad_pt_rc, stamp=$([[ -f "$ad_pt_stamp" ]] && echo yes || echo no), out=${ad_pt_out:0:200})"
fi

# =============================================================================
# Test 18 — GH#20946: _isc_has_label helper returns 0/1/2 correctly
#
# Direct unit test of the new probe helper. Exercises present/absent paths.
# =============================================================================
export STUB_ISSUE_HAS_IN_REVIEW=0
export STUB_ISSUE_HAS_AUTO_DISPATCH=1
export STUB_ISSUE_HAS_PARENT_TASK=0

_isc_has_label 60004 carveout/test "auto-dispatch"
label_present_rc=$?

_isc_has_label 60004 carveout/test "parent-task"
label_absent_rc=$?

_isc_has_label 60004 carveout/test "status:in-review"
label_other_absent_rc=$?

if [[ $label_present_rc -eq 0 && $label_absent_rc -eq 1 && $label_other_absent_rc -eq 1 ]]; then
	print_result "GH#20946: _isc_has_label returns 0 for present, 1 for absent" 0
else
	print_result "GH#20946: _isc_has_label returns 0 for present, 1 for absent" 1 \
		"(present_rc=$label_present_rc, absent_rc=$label_absent_rc, other_absent_rc=$label_other_absent_rc)"
fi

# Reset stub state to avoid polluting any tests added below
export STUB_ISSUE_HAS_AUTO_DISPATCH=0
export STUB_ISSUE_HAS_PARENT_TASK=0

# =============================================================================
# Test 19 — GH#20946 PR #20977 review: _isc_carve_out_required returns
# 0 / 1 / 1 / 2 across the full matrix.
#
# Consolidated single-call helper that replaces the original two-call
# (`_isc_has_label auto-dispatch` + `_isc_has_label parent-task`) probe
# pattern. Two review findings closed in one helper:
#   - augmentcode (medium): the inner `if !` for parent-task conflated rc=1
#     (label absent → carve-out applies) with rc=2 (gh lookup failed →
#     intent unknown), failing CLOSED on transient errors. The new helper
#     surfaces rc=2 as a distinct return value so the caller can fail OPEN.
#   - gemini-code-assist (medium): two `gh issue view` calls in the claim
#     hot path consolidated to one round-trip via a combined jq predicate.
#
# Sub-cases:
#   1. auto-dispatch present + parent-task absent → rc=0 (carve-out applies)
#   2. auto-dispatch present + parent-task present → rc=1 (parent-task exempt)
#   3. auto-dispatch absent → rc=1 (no carve-out needed)
#   4. gh lookup fails → rc=2 (fail-OPEN signal — caller proceeds with claim)
# =============================================================================
export STUB_ISSUE_HAS_IN_REVIEW=0
export STUB_GH_VIEW_FAILS=0

# Sub-case 1: auto-dispatch + no parent-task → carve-out applies (rc=0)
export STUB_ISSUE_HAS_AUTO_DISPATCH=1
export STUB_ISSUE_HAS_PARENT_TASK=0
_isc_carve_out_required 60005 carveout/test
co_apply_rc=$?

# Sub-case 2: auto-dispatch + parent-task → exempt (rc=1)
export STUB_ISSUE_HAS_AUTO_DISPATCH=1
export STUB_ISSUE_HAS_PARENT_TASK=1
_isc_carve_out_required 60005 carveout/test
co_exempt_rc=$?

# Sub-case 3: no auto-dispatch → no carve-out (rc=1)
export STUB_ISSUE_HAS_AUTO_DISPATCH=0
export STUB_ISSUE_HAS_PARENT_TASK=0
_isc_carve_out_required 60005 carveout/test
co_absent_rc=$?

# Sub-case 4: gh issue view fails → fail-OPEN signal (rc=2)
export STUB_GH_VIEW_FAILS=1
_isc_carve_out_required 60005 carveout/test
co_failopen_rc=$?
export STUB_GH_VIEW_FAILS=0

if [[ $co_apply_rc -eq 0 && $co_exempt_rc -eq 1 && $co_absent_rc -eq 1 && $co_failopen_rc -eq 2 ]]; then
	print_result "GH#20946 review: _isc_carve_out_required returns 0/1/1/2 across matrix" 0
else
	print_result "GH#20946 review: _isc_carve_out_required returns 0/1/1/2 across matrix" 1 \
		"(apply=$co_apply_rc, exempt=$co_exempt_rc, absent=$co_absent_rc, failopen=$co_failopen_rc)"
fi

# Reset stub state
export STUB_ISSUE_HAS_AUTO_DISPATCH=0
export STUB_ISSUE_HAS_PARENT_TASK=0

# =============================================================================
# Test 20 — ownership metadata failure fails closed without a stamp.
#
# Ownership-aware idempotency cannot safely classify the incumbent when the
# bounded metadata read fails. It must not mutate GitHub or write caller-owned
# stamp evidence in that state.
# =============================================================================
fo_stamp=$(_isc_stamp_path 60006 carveout/failopen)
rm -f "$fo_stamp" >/dev/null 2>&1 || true
: >"$STUB_LOG"
fo_out=$(STUB_ISSUE_HAS_IN_REVIEW=0 STUB_ISSUE_HAS_AUTO_DISPATCH=1 STUB_ISSUE_HAS_PARENT_TASK=0 \
	STUB_GH_VIEW_FAILS=1 STUB_GH_MODE=online \
	_isc_cmd_claim 60006 carveout/failopen 2>&1)
fo_rc=$?

if [[ $fo_rc -eq 1 ]] &&
	! grep -q 'issue edit 60006' "$STUB_LOG" &&
	[[ ! -f "$fo_stamp" ]] &&
	printf '%s' "$fo_out" | grep -q 'ownership metadata unavailable'; then
	print_result "ownership metadata failure writes no stamp or GitHub state" 0
else
	print_result "ownership metadata failure writes no stamp or GitHub state" 1 \
		"(rc=$fo_rc, stamp=$([[ -f "$fo_stamp" ]] && echo yes || echo no), out=${fo_out:0:200})"
fi

# Reset stub state
export STUB_ISSUE_HAS_AUTO_DISPATCH=0

# =============================================================================
# Test 21 — external non-maintainer repos skip interactive claim lifecycle
#
# The claim routine exists to coordinate with our pulse on repos we manage. On
# external upstream repos, applying labels/assignees or posting claim comments
# looks like public spam. Read-only permission must therefore no-op: no stamp,
# no issue edit, no issue comment.
# =============================================================================
external_stamp=$(_isc_stamp_path 61001 external/repo)
rm -f "$external_stamp" >/dev/null 2>&1 || true
: >"$STUB_LOG"
external_out=$(STUB_PERMISSION=read STUB_ISSUE_HAS_IN_REVIEW=0 STUB_GH_MODE=online \
	_isc_cmd_claim 61001 external/repo --worktree /tmp/external-wt 2>&1)
external_rc=$?

if [[ $external_rc -eq 0 ]] &&
	[[ ! -f "$external_stamp" ]] &&
	! grep -q 'issue edit 61001' "$STUB_LOG" &&
	! grep -q 'issue comment 61001' "$STUB_LOG" &&
	printf '%s' "$external_out" | grep -q 'external repos'; then
	print_result "external non-maintainer claim skips labels and comments" 0
else
	external_log=$(tr '\n' '|' <"$STUB_LOG")
	print_result "external non-maintainer claim skips labels and comments" 1 \
		"(rc=$external_rc, stamp=$([[ -f "$external_stamp" ]] && echo yes || echo no), log=${external_log}, out=${external_out:0:200})"
fi

# =============================================================================
# Test 22 — permission lookup failure fails closed for public claim lifecycle
# =============================================================================
lookup_fail_stamp=$(_isc_stamp_path 61002 external/fail)
rm -f "$lookup_fail_stamp" >/dev/null 2>&1 || true
: >"$STUB_LOG"
lookup_fail_out=$(STUB_PERMISSION_FAIL=1 STUB_ISSUE_HAS_IN_REVIEW=0 STUB_GH_MODE=online \
	_isc_cmd_claim 61002 external/fail --worktree /tmp/external-wt 2>&1)
lookup_fail_rc=$?

if [[ $lookup_fail_rc -eq 0 ]] &&
	[[ ! -f "$lookup_fail_stamp" ]] &&
	! grep -q 'issue edit 61002' "$STUB_LOG" &&
	printf '%s' "$lookup_fail_out" | grep -q 'not a maintainer-equivalent collaborator'; then
	print_result "permission lookup failure skips public claim lifecycle" 0
else
	lookup_fail_log=$(tr '\n' '|' <"$STUB_LOG")
	print_result "permission lookup failure skips public claim lifecycle" 1 \
		"(rc=$lookup_fail_rc, stamp=$([[ -f "$lookup_fail_stamp" ]] && echo yes || echo no), log=${lookup_fail_log}, out=${lookup_fail_out:0:200})"
fi

# =============================================================================
# Test 23 — GH#21805: release on an OPEN issue applies status:available
# (existing behaviour preserved).
# =============================================================================
export STUB_PERMISSION_FAIL=0
export STUB_PERMISSION=admin
export STUB_GH_MODE=online
_isc_cmd_claim 70001 testowner/testrepo --worktree /tmp/wt-fake >/dev/null 2>&1
: >"$STUB_LOG"
export STUB_ISSUE_HAS_IN_REVIEW=1
export STUB_ISSUE_STATE=OPEN
_isc_cmd_release 70001 testowner/testrepo >/dev/null 2>&1
release_open_rc=$?
release_open_log=$(cat "$STUB_LOG")
export STUB_ISSUE_STATE=

if [[ $release_open_rc -eq 0 ]] && printf '%s' "$release_open_log" | grep -q "remove-label status:in-review" && printf '%s' "$release_open_log" | grep -q "add-label status:available"; then
	print_result "GH#21805: release on OPEN issue → status:available" 0
else
	print_result "GH#21805: release on OPEN issue → status:available" 1 \
		"(rc=$release_open_rc, log=${release_open_log:0:300})"
fi

# =============================================================================
# Test 24 — GH#21805: release on a CLOSED issue applies status:done instead of
# status:available, preventing label pollution on closed issues.
# =============================================================================
_isc_cmd_claim 70002 testowner/testrepo --worktree /tmp/wt-fake >/dev/null 2>&1
: >"$STUB_LOG"
export STUB_ISSUE_HAS_IN_REVIEW=1
export STUB_ISSUE_STATE=CLOSED
_isc_cmd_release 70002 testowner/testrepo >/dev/null 2>&1
release_closed_rc=$?
release_closed_log=$(cat "$STUB_LOG")
export STUB_ISSUE_STATE=

# Must apply status:done, must NOT apply status:available
if [[ $release_closed_rc -eq 0 ]] && printf '%s' "$release_closed_log" | grep -q "add-label status:done" && ! printf '%s' "$release_closed_log" | grep -q "add-label status:available"; then
	print_result "GH#21805: release on CLOSED issue → status:done, not status:available" 0
else
	print_result "GH#21805: release on CLOSED issue → status:done, not status:available" 1 \
		"(rc=$release_closed_rc, log=${release_closed_log:0:300})"
fi

# REST fallback reads return the GitHub issue state in lowercase. Preserve the
# same closed-issue invariant when that path supplies `closed` (GH#27869).
_isc_cmd_claim 70004 testowner/testrepo --worktree /tmp/wt-fake >/dev/null 2>&1
: >"$STUB_LOG"
export STUB_ISSUE_HAS_IN_REVIEW=1
export STUB_ISSUE_STATE=closed
_isc_cmd_release 70004 testowner/testrepo >/dev/null 2>&1
release_rest_closed_rc=$?
release_rest_closed_log=$(cat "$STUB_LOG")
export STUB_ISSUE_STATE=

if [[ $release_rest_closed_rc -eq 0 ]] && printf '%s' "$release_rest_closed_log" | grep -q "add-label status:done" && ! printf '%s' "$release_rest_closed_log" | grep -q "add-label status:available"; then
	print_result "GH#27869: release on lowercase closed issue → status:done, not status:available" 0
else
	print_result "GH#27869: release on lowercase closed issue → status:done, not status:available" 1 \
		"(rc=$release_rest_closed_rc, log=${release_rest_closed_log:0:300})"
fi

# Reset stub state
export STUB_ISSUE_HAS_IN_REVIEW=0

# =============================================================================
# Test 25 — GH#27834: release --unassign remains actionable after another
# lifecycle path has already moved the issue to status:available.
# =============================================================================
export STUB_ISSUE_HAS_IN_REVIEW=0
export STUB_GH_VIEW_FAILS=0
: >"$STUB_LOG"
_isc_cmd_release 70003 testuser/testrepo --unassign >/dev/null 2>&1
release_available_rc=$?
release_available_log=$(cat "$STUB_LOG")

if [[ $release_available_rc -eq 0 ]] &&
	printf '%s' "$release_available_log" | grep -q "issue edit 70003 --repo testuser/testrepo --remove-assignee testuser" &&
	! printf '%s' "$release_available_log" | grep -q "remove-label status:in-review" &&
	! printf '%s' "$release_available_log" | grep -q "add-label status:available"; then
	print_result "GH#27834: already-available release --unassign removes self-assignment only" 0
else
	print_result "GH#27834: already-available release --unassign removes self-assignment only" 1 \
		"(rc=$release_available_rc, log=${release_available_log:0:300})"
fi

# A repeated call is harmless and still requests the idempotent removal.
: >"$STUB_LOG"
_isc_cmd_release 70003 testuser/testrepo --unassign >/dev/null 2>&1
release_available_repeat_rc=$?
release_available_repeat_log=$(cat "$STUB_LOG")
if [[ $release_available_repeat_rc -eq 0 ]] &&
	printf '%s' "$release_available_repeat_log" | grep -q -- "--remove-assignee testuser"; then
	print_result "GH#27834: already-available release --unassign is idempotent" 0
else
	print_result "GH#27834: already-available release --unassign is idempotent" 1 \
		"(rc=$release_available_repeat_rc, log=${release_available_repeat_log:0:300})"
fi

# A failed unassignment is captured under `set -e` so the documented warning-
# only release contract is preserved instead of aborting the caller.
release_unassign_fail_out=$(
	set -e
	STUB_GH_EDIT_FAILS=1 _isc_unassign_released_issue 70003 testuser/testrepo testuser 2>&1
)
release_unassign_fail_rc=$?
if [[ $release_unassign_fail_rc -eq 0 ]] &&
	printf '%s' "$release_unassign_fail_out" | grep -q "(rc=1): simulated issue edit failure"; then
	print_result "GH#27834: failed standalone unassignment remains warning-only under set -e" 0
else
	print_result "GH#27834: failed standalone unassignment remains warning-only under set -e" 1 \
		"(rc=$release_unassign_fail_rc, out=${release_unassign_fail_out:0:300})"
fi

# Without --unassign, already-available remains a complete no-op.
: >"$STUB_LOG"
_isc_cmd_release 70004 testuser/testrepo >/dev/null 2>&1
release_available_noop_rc=$?
release_available_noop_log=$(cat "$STUB_LOG")
if [[ $release_available_noop_rc -eq 0 ]] &&
	! printf '%s' "$release_available_noop_log" | grep -q "issue edit 70004"; then
	print_result "GH#27834: already-available release without --unassign stays unchanged" 0
else
	print_result "GH#27834: already-available release without --unassign stays unchanged" 1 \
		"(rc=$release_available_noop_rc, log=${release_available_noop_log:0:300})"
fi

# A failed three-state label lookup preserves the warning/fail-open path and
# does not guess whether a standalone unassignment is safe.
: >"$STUB_LOG"
release_lookup_out=$(STUB_GH_VIEW_FAILS=1 _isc_cmd_release 70005 testuser/testrepo --unassign 2>&1)
release_lookup_rc=$?
release_lookup_log=$(cat "$STUB_LOG")
if [[ $release_lookup_rc -eq 0 ]] &&
	printf '%s' "$release_lookup_out" | grep -q "could not read labels" &&
	! printf '%s' "$release_lookup_log" | grep -q "issue edit 70005"; then
	print_result "GH#27834: release label lookup failure remains warning-only" 0
else
	print_result "GH#27834: release label lookup failure remains warning-only" 1 \
		"(rc=$release_lookup_rc, log=${release_lookup_log:0:300}, out=${release_lookup_out:0:200})"
fi

# =============================================================================
# Test 26 — issue-start marker fails closed without explicit takeover
# =============================================================================
marker_out=$(AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION=1 \
	_isc_cmd_claim 70006 testowner/testrepo --worktree /tmp/wt-fake 2>&1)
marker_rc=$?

if [[ $marker_rc -eq 2 ]] && printf '%s' "$marker_out" | grep -q 'requires --implementing'; then
	print_result "issue-start marker rejects worker-style claim routing" 0
else
	print_result "issue-start marker rejects worker-style claim routing" 1 \
		"(rc=$marker_rc, out=${marker_out:0:200})"
fi

# =============================================================================
# Test 27 — GH#27871: closed issues skip every interactive claim write
# =============================================================================
for closed_state in CLOSED closed; do
	closed_stamp=$(_isc_stamp_path 70007 closed/test)
	rm -f "$closed_stamp" >/dev/null 2>&1 || true
	: >"$STUB_LOG"
	closed_out=$(STUB_ISSUE_STATE="$closed_state" STUB_ISSUE_HAS_IN_REVIEW=1 \
		_isc_cmd_claim 70007 closed/test --worktree /tmp/closed-wt --implementing 2>&1)
	closed_rc=$?
	closed_log=$(cat "$STUB_LOG")

	if [[ $closed_rc -eq 0 && ! -f "$closed_stamp" &&
		"$closed_out" == *"is closed"* &&
		"$closed_log" != *"issue edit 70007"* &&
		"$closed_log" != *"issue comment 70007"* ]]; then
		print_result "GH#27871: claim on ${closed_state} issue skips lifecycle writes" 0
	else
		print_result "GH#27871: claim on ${closed_state} issue skips lifecycle writes" 1 \
			"(rc=$closed_rc, stamp=$([[ -f "$closed_stamp" ]] && echo yes || echo no), log=${closed_log:0:300}, out=${closed_out:0:200})"
	fi
done

# =============================================================================
# Summary
# =============================================================================
printf '\n'
printf 'Tests run:    %d\n' "$TESTS_RUN"
printf 'Tests failed: %d\n' "$TESTS_FAILED"

if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%sAll tests passed%s\n' "$TEST_GREEN" "$TEST_RESET"
	exit 0
else
	printf '%s%d test(s) failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TEST_RESET"
	exit 1
fi
