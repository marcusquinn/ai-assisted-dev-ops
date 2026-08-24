#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-peer-productivity-monitor.sh
#
# Unit tests for peer-productivity-monitor.sh (t2932). Covers the pure-logic
# helpers that don't touch the GitHub API:
#   - bot detection (_is_bot)
#   - login → variable name conversion (_login_to_var)
#   - action sanitization (_sanitize_action)
#   - vote computation (_vote_for_peer)
#   - hysteresis (_apply_hysteresis): flap-prevention, flip-after-3-cycles,
#     keep-vote preserves current action, manual-override sticky
#   - dispatch-override.conf rewrite preserves manual entries above marker
#   - default action for unknown peers (honour, since "ignore" requires
#     active claims observed in the API path)
#
# Uses isolated temp HOME to avoid touching production state.
#
# Usage: bash tests/test-peer-productivity-monitor.sh
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_DIR/.agents/scripts/peer-productivity-monitor.sh"

# --- Test framework ---
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;32mPASS\033[0m %s\n" "$1"
	return 0
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
	[[ -n "${2:-}" ]] && printf "       %s\n" "$2"
	return 0
}

section() {
	echo ""
	printf "\033[1m=== %s ===\033[0m\n" "$1"
	return 0
}

# --- Isolated env ---
TEST_DIR=$(mktemp -d)
HOME_BACKUP="$HOME"
export HOME="$TEST_DIR/home"
mkdir -p "$HOME/.aidevops/state" "$HOME/.aidevops/logs" "$HOME/.config/aidevops"

# shellcheck disable=SC2064
trap "HOME='$HOME_BACKUP'; rm -rf '$TEST_DIR'" EXIT

# --- Prereq ---
if [[ ! -x "$SCRIPT_UNDER_TEST" ]]; then
	echo "ERROR: $SCRIPT_UNDER_TEST not executable"
	exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "ERROR: jq required for tests"
	exit 1
fi

# Source script with main() stripped so we can call helpers directly. The
# script's `set -euo pipefail` would otherwise abort the test runner on the
# first helper that returns non-zero (e.g. `_is_bot alice` → 1). Restore the
# permissive mode after sourcing.
eval "$(sed 's/^main "$@"$//' "$SCRIPT_UNDER_TEST")"
set +e
set +u
set +o pipefail

# ============================================================================
section "Bot detection (_is_bot)"
# ============================================================================

test_bot_detection() {
	local cases=(
		"dependabot[bot]:0"
		"renovate[bot]:0"
		"github-actions[bot]:0"
		"some-bot:0"
		"my-cool-bot:0"
		"alice:1"
		"alex-solovyev:1"
		"marcusquinn:1"
	)
	for c in "${cases[@]}"; do
		local login="${c%:*}"
		local expected="${c##*:}"
		_is_bot "$login"
		local actual=$?
		if [[ "$actual" == "$expected" ]]; then
			pass "_is_bot $login = $actual"
		else
			fail "_is_bot $login: expected $expected, got $actual"
		fi
	done
	return 0
}
test_bot_detection

# ============================================================================
section "Login → variable name (_login_to_var)"
# ============================================================================

test_login_to_var() {
	local result
	result=$(_login_to_var "alex-solovyev")
	if [[ "$result" == "ALEX_SOLOVYEV" ]]; then
		pass "alex-solovyev → ALEX_SOLOVYEV"
	else
		fail "alex-solovyev: expected ALEX_SOLOVYEV, got $result"
	fi

	result=$(_login_to_var "marcusquinn")
	if [[ "$result" == "MARCUSQUINN" ]]; then
		pass "marcusquinn → MARCUSQUINN"
	else
		fail "marcusquinn: expected MARCUSQUINN, got $result"
	fi

	result=$(_login_to_var "user-with-many-dashes")
	if [[ "$result" == "USER_WITH_MANY_DASHES" ]]; then
		pass "multi-dash login converted"
	else
		fail "multi-dash: got $result"
	fi
	return 0
}
test_login_to_var

# ============================================================================
section "Action sanitization (_sanitize_action)"
# ============================================================================

test_sanitize_action() {
	local cases=(
		"ignore:ignore"
		"honour:honour"
		"warn:warn"
		"; rm -rf /:honour"
		"\${EVIL}:honour"
		"random_value:honour"
		":honour"
	)
	for c in "${cases[@]}"; do
		local input="${c%:*}"
		local expected="${c##*:}"
		local actual
		actual=$(_sanitize_action "$input")
		if [[ "$actual" == "$expected" ]]; then
			pass "_sanitize_action '$input' = '$actual'"
		else
			fail "_sanitize_action '$input': expected '$expected', got '$actual'"
		fi
	done
	return 0
}
test_sanitize_action

# ============================================================================
section "Vote computation (_vote_for_peer)"
# ============================================================================

test_vote_for_peer() {
	local cases=(
		# active_claims:worker_prs:expected_vote
		"0:0:keep"      # no signal → keep
		"1:0:keep"      # single claim, no PRs → insufficient data (< 2 threshold) → keep
		"2:0:ignore"    # 2 claims, no PRs → broken pulse (meets >=2 threshold) → ignore
		"5:0:ignore"    # 5 claims but no PRs → broken pulse → ignore
		"0:1:honour"    # no claims, 1 PR → recovered → honour
		"1:1:honour"    # 1 claim + 1 PR → productive → honour (merges win)
		"5:1:honour"    # claims AND PRs → working, just slow → honour
		"10:3:honour"   # productive peer → honour
		"3:0:ignore"    # 3 claims, no PRs → broken → ignore
	)
	for c in "${cases[@]}"; do
		IFS=: read -r ac wp expected <<<"$c"
		local actual
		actual=$(_vote_for_peer "$ac" "$wp")
		if [[ "$actual" == "$expected" ]]; then
			pass "vote(claims=$ac, prs=$wp) = $actual"
		else
			fail "vote(claims=$ac, prs=$wp): expected $expected, got $actual"
		fi
	done
	return 0
}
test_vote_for_peer

# ============================================================================
section "Per-repository campaign fitness"
# ============================================================================

test_repository_fitness() {
	local healthy broken idle saturated
	healthy=$(_repository_fitness 1 2)
	broken=$(_repository_fitness 3 0)
	idle=$(_repository_fitness 1 0)
	saturated=$(_repository_fitness 0 9)
	if [[ "$healthy" == "80" && "$broken" == "15" && "$idle" == "50" && "$saturated" == "100" ]]; then
		pass "repository fitness is bounded and productivity-aware"
	else
		fail "repository fitness mismatch" "healthy=$healthy broken=$broken idle=$idle saturated=$saturated"
	fi
	return 0
}
test_repository_fitness

test_repository_observation_aggregation() {
	local observations aggregated
	observations='{"login":"alice","repo":"example/alpha","active_claims":3,"worker_prs":0,"interactive_prs":1}
{"login":"alice","repo":"example/beta","active_claims":0,"worker_prs":1,"interactive_prs":0}
{"login":"bob","repo":"example/alpha","active_claims":1,"worker_prs":0,"interactive_prs":0}'
	aggregated=$(printf '%s\n' "$observations" | _aggregate_peer_observations)
	if printf '%s' "$aggregated" | jq -e '
		(length == 2) and
		(.[0].login == "alice") and
		(.[0].active_claims == 3) and
		(.[0].worker_prs == 1) and
		(.[0].repositories["example/alpha"].fitness == 15) and
		(.[0].repositories["example/beta"].fitness == 70) and
		(.[1].repositories["example/alpha"].fitness == 50)
	' >/dev/null; then
		pass "aggregation retains bounded per-repository fitness"
	else
		fail "aggregation lost per-repository fitness" "$aggregated"
	fi
	return 0
}
test_repository_observation_aggregation

test_repository_observation_state_attachment() {
	local peer_state repositories enriched
	peer_state='{"alice":{"current_action":"honour","vote_history":["keep"],"last_observed":"2026-01-01T00:00:00Z"}}'
	repositories='{"example/alpha":{"active_claims":1,"worker_prs":0,"interactive_prs":0,"fitness":50}}'
	enriched=$(_attach_repository_observations "$peer_state" "alice" "$repositories")
	if printf '%s' "$enriched" | jq -e '
		(.alice.current_action == "honour") and
		(.alice.vote_history == ["keep"]) and
		(.alice.repos == ["example/alpha"]) and
		(.alice.repositories["example/alpha"].fitness == 50)
	' >/dev/null; then
		pass "per-repository fitness persists additively beside hysteresis state"
	else
		fail "per-repository fitness overwrote hysteresis state" "$enriched"
	fi
	return 0
}
test_repository_observation_state_attachment

# ============================================================================
section "Hysteresis (_apply_hysteresis)"
# ============================================================================

# Helper to extract a peer's current_action from the merged state JSON returned
# by _apply_hysteresis (single-peer slice).
_extract_action() {
	local peer_state="$1"
	local login="$2"
	printf '%s' "$peer_state" | jq -r --arg l "$login" '.[$l].current_action'
	return 0
}

_extract_history() {
	local peer_state="$1"
	local login="$2"
	printf '%s' "$peer_state" | jq -r --arg l "$login" '.[$l].vote_history | join(",")'
	return 0
}

test_hysteresis_first_observation_no_flip() {
	# First "ignore" vote on a fresh peer (default current_action=honour) — must
	# NOT flip yet. History gets one entry, but current_action stays honour.
	local state='{}'
	local result
	result=$(_apply_hysteresis "$state" "alice" "ignore")
	local action history
	action=$(_extract_action "$result" "alice")
	history=$(_extract_history "$result" "alice")
	if [[ "$action" == "honour" ]] && [[ "$history" == "ignore" ]]; then
		pass "first ignore vote: action=honour history=ignore"
	else
		fail "first ignore vote: action=$action history=$history"
	fi
	return 0
}
test_hysteresis_first_observation_no_flip

test_hysteresis_three_consecutive_flips() {
	# Three consecutive "ignore" votes flip honour → ignore.
	local state='{}'
	local r1 r2 r3
	r1=$(_apply_hysteresis "$state" "alice" "ignore")
	state=$(printf '%s\n%s' "$state" "$r1" | jq -s '.[0] * .[1]')
	r2=$(_apply_hysteresis "$state" "alice" "ignore")
	state=$(printf '%s\n%s' "$state" "$r2" | jq -s '.[0] * .[1]')
	r3=$(_apply_hysteresis "$state" "alice" "ignore")
	local action history
	action=$(_extract_action "$r3" "alice")
	history=$(_extract_history "$r3" "alice")
	if [[ "$action" == "ignore" ]] && [[ "$history" == "ignore,ignore,ignore" ]]; then
		pass "3x ignore flips honour → ignore"
	else
		fail "3x ignore: action=$action history=$history"
	fi
	return 0
}
test_hysteresis_three_consecutive_flips

test_hysteresis_flap_prevention() {
	# 2 ignore + 1 honour + 2 ignore should NOT flip — the run isn't 3 in a row.
	local state='{}'
	local r
	for vote in ignore ignore honour ignore ignore; do
		r=$(_apply_hysteresis "$state" "alice" "$vote")
		state=$(printf '%s\n%s' "$state" "$r" | jq -s '.[0] * .[1]')
	done
	local action history
	action=$(_extract_action "$state" "alice")
	history=$(_extract_history "$state" "alice")
	if [[ "$action" == "honour" ]]; then
		pass "interleaved votes don't flip (action=honour, history=$history)"
	else
		fail "interleaved votes flipped early: action=$action history=$history"
	fi
	return 0
}
test_hysteresis_flap_prevention

test_hysteresis_recovery_flip_back() {
	# Peer ignored, then 3 honour votes restore honour.
	local state='{"alice":{"current_action":"ignore","vote_history":["ignore","ignore","ignore"],"last_observed":"2026-01-01T00:00:00Z"}}'
	local r
	for vote in honour honour honour; do
		r=$(_apply_hysteresis "$state" "alice" "$vote")
		state=$(printf '%s\n%s' "$state" "$r" | jq -s '.[0] * .[1]')
	done
	local action
	action=$(_extract_action "$state" "alice")
	if [[ "$action" == "honour" ]]; then
		pass "3x honour restores ignored peer to honour"
	else
		fail "recovery: expected honour, got $action"
	fi
	return 0
}
test_hysteresis_recovery_flip_back

test_hysteresis_keep_preserves_action() {
	# A "keep" vote should not change current_action even if it's the only
	# vote so far.
	local state='{}'
	local r
	r=$(_apply_hysteresis "$state" "bob" "keep")
	local action
	action=$(_extract_action "$r" "bob")
	if [[ "$action" == "honour" ]]; then
		pass "keep vote on fresh peer leaves action=honour"
	else
		fail "keep vote: expected honour, got $action"
	fi

	# Keep votes on an already-ignored peer must not flip back.
	state='{"bob":{"current_action":"ignore","vote_history":["ignore","ignore","ignore"],"last_observed":"2026-01-01T00:00:00Z"}}'
	for _ in 1 2 3 4 5; do
		r=$(_apply_hysteresis "$state" "bob" "keep")
		state=$(printf '%s\n%s' "$state" "$r" | jq -s '.[0] * .[1]')
	done
	action=$(_extract_action "$state" "bob")
	if [[ "$action" == "ignore" ]]; then
		pass "5x keep on ignored peer preserves ignore"
	else
		fail "keep on ignored: expected ignore, got $action"
	fi
	return 0
}
test_hysteresis_keep_preserves_action

# ============================================================================
section "Authenticated self identity validation"
# ============================================================================

test_self_login_rejects_api_error_payload() {
	gh() {
		printf '{"message":"API rate limit exceeded"}\n'
		return 0
	}
	local output="" rc=0
	output=$(_self_login) || rc=$?
	unset -f gh
	if [[ "$rc" -ne 0 && -z "$output" ]]; then
		pass "self login rejects API error payloads"
	else
		fail "self login accepted an API error payload" "rc=$rc output=$output"
	fi
	return 0
}
test_self_login_rejects_api_error_payload

# ============================================================================
section "Override config rewrite preserves manual entries"
# ============================================================================

test_rewrite_preserves_manual_entries() {
	local conf="$HOME/.config/aidevops/dispatch-override.conf"
	# Manual content above (and after) the marker block must survive rewrite.
	cat >"$conf" <<'EOF'
# User's manual config
DISPATCH_OVERRIDE_ENABLED=true
DISPATCH_OVERRIDE_MY_TRUSTED_PEER="honour"
EOF

	# Override the OVERRIDE_CONF inside the sourced script for this test
	OVERRIDE_CONF="$conf"

	local state='{"alice":{"current_action":"ignore","vote_history":["ignore","ignore","ignore"],"last_observed":"2026-01-01T00:00:00Z"}}'
	_rewrite_override_config "$state"

	if grep -qF 'DISPATCH_OVERRIDE_MY_TRUSTED_PEER="honour"' "$conf"; then
		pass "manual entry above marker preserved"
	else
		fail "manual entry lost"
	fi
	if grep -qF 'DISPATCH_OVERRIDE_ENABLED=true' "$conf"; then
		pass "DISPATCH_OVERRIDE_ENABLED preserved"
	else
		fail "DISPATCH_OVERRIDE_ENABLED lost"
	fi
	if grep -qF 'DISPATCH_OVERRIDE_ALICE="ignore"' "$conf"; then
		pass "auto-managed entry written"
	else
		fail "auto-managed entry missing"
	fi
	if grep -qF 'BEGIN auto-managed by peer-productivity-monitor' "$conf"; then
		pass "BEGIN marker present"
	else
		fail "BEGIN marker missing"
	fi
	return 0
}
test_rewrite_preserves_manual_entries

test_rewrite_idempotent() {
	# Running rewrite twice must produce the same content for the same state
	# (modulo the timestamp comment line).
	local conf="$HOME/.config/aidevops/dispatch-override.conf"
	cat >"$conf" <<'EOF'
DISPATCH_OVERRIDE_ENABLED=true
EOF
	OVERRIDE_CONF="$conf"

	local state='{"alice":{"current_action":"ignore","vote_history":["ignore","ignore","ignore"],"last_observed":"2026-01-01T00:00:00Z"}}'
	_rewrite_override_config "$state"
	local first_rewrite
	first_rewrite=$(grep -v "Last rewrite:" "$conf")
	_rewrite_override_config "$state"
	local second_rewrite
	second_rewrite=$(grep -v "Last rewrite:" "$conf")
	if [[ "$first_rewrite" == "$second_rewrite" ]]; then
		pass "rewrite is idempotent (modulo timestamp)"
	else
		fail "rewrite produces drift"
	fi
	return 0
}
test_rewrite_idempotent

test_rewrite_drops_honour_entries() {
	# A peer with current_action=honour should NOT produce a config line
	# (honour is the implicit default — no need to clutter the file).
	local conf="$HOME/.config/aidevops/dispatch-override.conf"
	cat >"$conf" <<'EOF'
DISPATCH_OVERRIDE_ENABLED=true
EOF
	OVERRIDE_CONF="$conf"

	local state='{"alice":{"current_action":"honour","vote_history":["honour","honour","honour"],"last_observed":"2026-01-01T00:00:00Z"}}'
	_rewrite_override_config "$state"
	if ! grep -qF 'DISPATCH_OVERRIDE_ALICE' "$conf"; then
		pass "honour-state peer not written to config"
	else
		fail "honour-state peer leaked into config"
	fi
	return 0
}
test_rewrite_drops_honour_entries

test_rewrite_drops_authenticated_self_entry() {
	local conf="$HOME/.config/aidevops/dispatch-override.conf"
	cat >"$conf" <<'EOF'
DISPATCH_OVERRIDE_ENABLED=true
EOF
	OVERRIDE_CONF="$conf"

	local state='{"self-runner":{"current_action":"ignore","vote_history":["ignore","ignore","ignore"]},"alice":{"current_action":"ignore","vote_history":["ignore","ignore","ignore"]}}'
	_rewrite_override_config "$state" "self-runner"
	if ! grep -qF 'DISPATCH_OVERRIDE_SELF_RUNNER' "$conf" &&
		grep -qF 'DISPATCH_OVERRIDE_ALICE="ignore"' "$conf"; then
		pass "rewrite omits the authenticated runner while retaining peer overrides"
	else
		fail "rewrite emitted a self override or dropped a peer override"
	fi
	return 0
}
test_rewrite_drops_authenticated_self_entry

# ============================================================================
section "Observe cycle removes stale self state"
# ============================================================================

test_observe_removes_stale_self_state() {
	STATE_FILE="$HOME/.aidevops/state/peer-productivity-state.json"
	OVERRIDE_CONF="$HOME/.config/aidevops/dispatch-override.conf"
	DRY_RUN=0
	cat >"$STATE_FILE" <<'EOF'
{
  "self-runner": {"current_action":"ignore","vote_history":["ignore","ignore","ignore"]},
  "alice": {"current_action":"ignore","vote_history":["ignore","ignore","ignore"]}
}
EOF
	_self_login() {
		printf 'self-runner'
		return 0
	}
	discover_and_observe() {
		printf '[]\n'
		return 0
	}

	cmd_observe
	if jq -e 'has("self-runner") | not' "$STATE_FILE" >/dev/null &&
		! grep -qF 'DISPATCH_OVERRIDE_SELF_RUNNER' "$OVERRIDE_CONF" &&
		grep -qF 'DISPATCH_OVERRIDE_ALICE="ignore"' "$OVERRIDE_CONF"; then
		pass "observe removes stale self state even when no peers are discovered"
	else
		fail "observe retained stale authenticated self state"
	fi
	return 0
}
test_observe_removes_stale_self_state

# ============================================================================
section "Claim regression — broken-peer detection (GH#21135)"
# ============================================================================
# These tests specifically exercise the claim-but-no-merge regression case:
# a peer whose runner CLAIMS issues but never merges should trigger `ignore`
# after 3 consecutive cycles of >=2 claims with 0 worker PRs.

test_claim_regression_single_claim_is_keep() {
	# A peer with exactly 1 open claim and 0 merges must vote `keep`
	# (insufficient data — 1 in-flight task is normal).
	local result
	result=$(_vote_for_peer 1 0)
	if [[ "$result" == "keep" ]]; then
		pass "1 claim + 0 merges = keep (single in-flight task is normal)"
	else
		fail "1 claim + 0 merges: expected keep, got $result"
	fi
	return 0
}
test_claim_regression_single_claim_is_keep

test_claim_regression_two_claims_is_ignore() {
	# 2+ open worker-labeled claims with 0 merges triggers the ignore vote.
	local r2 r3
	r2=$(_vote_for_peer 2 0)
	r3=$(_vote_for_peer 3 0)
	if [[ "$r2" == "ignore" ]] && [[ "$r3" == "ignore" ]]; then
		pass "2+ claims + 0 merges = ignore (broken peer)"
	else
		fail "2+ claims + 0 merges: expected ignore, got r2=$r2 r3=$r3"
	fi
	return 0
}
test_claim_regression_two_claims_is_ignore

test_claim_regression_hysteresis_three_cycles() {
	# Simulate a peer that was healthy, now breaks (claims but no merges).
	# After 3 consecutive cycles of ignore votes, the action flips to ignore.
	local state='{"brokenbot":{"current_action":"honour","vote_history":["honour","honour","honour"],"last_observed":"2026-01-01T00:00:00Z"}}'
	local r
	for _ in 1 2 3; do
		r=$(_apply_hysteresis "$state" "brokenbot" "ignore")
		state=$(printf '%s\n%s' "$state" "$r" | jq -s '.[0] * .[1]')
	done
	local action
	action=$(_extract_action "$state" "brokenbot")
	if [[ "$action" == "ignore" ]]; then
		pass "regression: 3x ignore cycles flip honour → ignore"
	else
		fail "regression: expected ignore after 3 cycles, got $action"
	fi
	return 0
}
test_claim_regression_hysteresis_three_cycles

test_claim_regression_merges_block_ignore() {
	# A peer with 2+ claims BUT also has merged PRs → vote is honour (productive).
	# The monitor must not penalise a peer that is both claiming and delivering.
	local cases=(
		"2:1"   # 2 claims, 1 merge → honour
		"5:1"   # 5 claims, 1 merge → honour
		"10:2"  # 10 claims, 2 merges → honour
	)
	for c in "${cases[@]}"; do
		IFS=: read -r claims prs <<<"$c"
		local result
		result=$(_vote_for_peer "$claims" "$prs")
		if [[ "$result" == "honour" ]]; then
			pass "vote(claims=$claims, merges=$prs) = honour (merges block ignore)"
		else
			fail "vote(claims=$claims, merges=$prs): expected honour, got $result"
		fi
	done
	return 0
}
test_claim_regression_merges_block_ignore

# ============================================================================
section "CLI smoke (help/report)"
# ============================================================================

test_cli_help() {
	if "$SCRIPT_UNDER_TEST" help 2>&1 | grep -q "peer-productivity-monitor"; then
		pass "help output contains script name"
	else
		fail "help output missing"
	fi
	return 0
}
test_cli_help

test_cli_report_no_state() {
	# With no state file, report should say so without erroring.
	rm -f "$HOME/.aidevops/state/peer-productivity-state.json"
	if "$SCRIPT_UNDER_TEST" report 2>&1 | grep -qiE "no state|state\.json"; then
		pass "report on empty state returns gracefully"
	else
		fail "report on empty state should report missing state"
	fi
	return 0
}
test_cli_report_no_state

# ============================================================================
section "Summary"
# ============================================================================

echo ""
printf "  Total:   %d\n" "$TOTAL_COUNT"
printf "  \033[0;32mPassed:  %d\033[0m\n" "$PASS_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
	printf "  \033[0;31mFailed:  %d\033[0m\n" "$FAIL_COUNT"
	exit 1
fi
echo ""
echo "All tests passed."
exit 0
