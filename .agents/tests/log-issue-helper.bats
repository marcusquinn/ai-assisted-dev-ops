#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for log-issue-helper.sh fingerprint dedup
# =============================================================================
# Run: bats .agents/tests/log-issue-helper.bats
#
# Covers GH#20813:
#   - _normalize_body_for_fingerprint strips sig footer and source trailers
#   - Cross-path dedup: same (title, body) filed via two paths hashes the same
#   - check_recent_filing / record_filing round-trip dedup
#
# shellcheck disable=SC2016
# Single-quoted printf format strings contain literal backticks (escaped \`...\`)
# and `$N` placeholders that are intentional test fixtures, not unexpanded
# expressions. Bats fixtures routinely use this pattern; SC2016 is a false
# positive in this file.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)/scripts"
HELPER="${SCRIPT_DIR}/log-issue-helper.sh"

# Use a temp state dir for each test run
setup() {
	export TEST_TMPDIR
	TEST_TMPDIR=$(mktemp -d)
	export HOME="$TEST_TMPDIR/home"
	mkdir -p "${HOME}/.aidevops/state"
	# Shorten dedup window to 60s for tests
	export LOG_ISSUE_DEDUP_WINDOW_SECONDS=60
}

teardown() {
	rm -rf "$TEST_TMPDIR"
}

# Source the helper once so functions are available across tests
_source_helper() {
	# shellcheck source=../scripts/log-issue-helper.sh
	source "$HELPER"
}

# =============================================================================
# _normalize_body_for_fingerprint
# =============================================================================

@test "_normalize_body_for_fingerprint: strips aidevops sig footer" {
	_source_helper
	local body
	body="$(printf 'Main body content\n<!-- aidevops:sig -->\nsome sig block')"
	local result
	result=$(_normalize_body_for_fingerprint "$body")
	[[ "$result" == "Main body content" ]]
}

@test "_normalize_body_for_fingerprint: strips Detected-by trailer and trailing ---" {
	_source_helper
	local body
	body="$(printf 'Main body content\n\n---\n*Detected by framework-routing-helper in \`owner/repo\`.*')"
	local result
	result=$(_normalize_body_for_fingerprint "$body")
	[[ "$result" == "Main body content" ]]
}

@test "_normalize_body_for_fingerprint: strips Detected-by but preserves mid-body ---" {
	_source_helper
	local body
	body="$(printf 'Section A\n\n---\n\nSection B\n\n---\n*Detected by framework-routing-helper in \`owner/repo\`.*')"
	local result
	result=$(_normalize_body_for_fingerprint "$body")
	# The mid-body --- should still be present; only trailing --- is stripped
	[[ "$result" == *"Section A"* ]] && [[ "$result" == *"Section B"* ]]
}

@test "_normalize_body_for_fingerprint: idempotent on body without suffix" {
	_source_helper
	local body="Plain issue body with no suffix"
	local result
	result=$(_normalize_body_for_fingerprint "$body")
	[[ "$result" == "$body" ]]
}

# =============================================================================
# _compute_issue_fingerprint: cross-path normalization
# =============================================================================

@test "_compute_issue_fingerprint: body with trailer == body without trailer" {
	_source_helper
	local title="test: fingerprint normalization"
	local body_plain="Some issue body text"
	local body_with_trailer
	body_with_trailer="$(printf '%s\n\n---\n*Detected by framework-routing-helper in \`owner/repo\`.*' "$body_plain")"

	local fp_plain fp_with_trailer
	fp_plain=$(_compute_issue_fingerprint "$title" "$body_plain")
	fp_with_trailer=$(_compute_issue_fingerprint "$title" "$body_with_trailer")

	[[ "$fp_plain" == "$fp_with_trailer" ]]
}

@test "_compute_issue_fingerprint: body with sig footer == body without sig footer" {
	_source_helper
	local title="test: sig footer normalization"
	local body_plain="Some issue body text"
	local body_with_sig
	body_with_sig="$(printf '%s\n<!-- aidevops:sig -->\nsig content' "$body_plain")"

	local fp_plain fp_with_sig
	fp_plain=$(_compute_issue_fingerprint "$title" "$body_plain")
	fp_with_sig=$(_compute_issue_fingerprint "$title" "$body_with_sig")

	[[ "$fp_plain" == "$fp_with_sig" ]]
}

@test "_compute_issue_fingerprint: different bodies produce different fingerprints" {
	_source_helper
	local fp1 fp2
	fp1=$(_compute_issue_fingerprint "title" "body A")
	fp2=$(_compute_issue_fingerprint "title" "body B")
	[[ "$fp1" != "$fp2" ]]
}

# =============================================================================
# check_recent_filing / record_filing round-trip
# =============================================================================

@test "validate brief rejects a heading-only reproducer" {
	_source_helper
	run validate_brief_has_reproducer "## Reproducer"
	[ "$status" -eq 1 ]
	[[ "$output" == *"requires **Symptom command**"* ]]
}

@test "validate brief rejects placeholder reproducer evidence" {
	_source_helper
	local body
	body="$(printf '## Reproducer\n**Symptom command**\n```\n<paste command here>\n```\n**Actual output**\n```\n<paste terminal output here>\n```')"
	run validate_brief_has_reproducer "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"placeholder evidence"* ]]
}

@test "validate brief rejects unsupported confirmed rate-limit attribution" {
	_source_helper
	local body
	body="$(printf '## Reproducer\n**Symptom command**\n```\nps -ef\n```\n**Actual output**\n```\npulse parent ran for 26 minutes\n```\nThe raw gh call hung because the API rate limit was exhausted.')"
	run validate_brief_has_reproducer "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"require **Blocked command** and **Backend state**"* ]]
}

@test "validate brief ignores transport-like substrings in confirmed causes" {
	_source_helper
	local body
	body="$(printf '## Reproducer\n**Symptom command**: aidevops review\n**Actual output**: reviewDecision=CHANGES_REQUESTED\n**Causal status**: confirmed\n**Production entry point**: review.sh:42 reads the review decision\n**Call chain**: review_tick -> read_decision -> classify_review\n**Integrated verification**: test-review.sh exercises the confirmed path\nThe root cause is CHANGES_REQUESTED, not hanger, transporter, timeoutSeconds, rate_limiter, or api_budgeter.')"
	run validate_brief_has_reproducer "$body"
	[ "$status" -eq 0 ]
}

@test "validate brief detects mixed-case transport tokens and explicit arrows" {
	_source_helper
	local claim body
	for claim in "root cause is a HANG" "worker HuNg because backend stopped" \
		"root cause is a Timeout" "request TIMED OUT because backend stopped" \
		"root cause is a Rate_Limit" "rate limit state preceded a hang" \
		"root cause is an API-BUDGET" \
		"root cause is a TrAnSpOrT failure" "pulse → gh api remained blocked"; do
		body="$(printf '## Reproducer\n**Symptom command**: aidevops pulse\n**Actual output**: operation stopped\n%s' "$claim")"
		run validate_brief_has_reproducer "$body"
		[ "$status" -eq 1 ]
		[[ "$output" == *"require **Blocked command** and **Backend state**"* ]]
	done
}

@test "validate brief accepts investigation framing without causal proof" {
	_source_helper
	local body
	body="$(printf '## Reproducer\n**Symptom command**\n```\nps -ef\n```\n**Actual output**\n```\npulse parent ran for 26 minutes\n```\nInvestigation: an untimed gh call is a candidate cause; causality is not established.')"
	run validate_brief_has_reproducer "$body"
	[ "$status" -eq 0 ]
}

@test "validate brief accepts confirmed transport claim with direct evidence" {
	_source_helper
	local body
	body="$(printf '## Reproducer\n**Symptom command**\n```\nps -ef --forest\n```\n**Actual output**\n```\npulse -> gh api rate_limit remained blocked\n```\n**Blocked command**: gh api rate_limit (PID 42)\n**Backend state**: x-ratelimit-remaining=0 captured at the same timestamp\n**Causal status**: confirmed\n**Owning-path proof**:\n- **Production entry point**: pulse.sh:42 invokes the rate-limit probe\n- **Call chain**: pulse_tick -> probe_budget -> gh api rate_limit\n- **Integrated verification**: bash tests/test-pulse-rate-limit.sh exercises pulse_tick\nThe exhausted rate limit caused the probe to hang.')"
	run validate_brief_has_reproducer "$body"
	[ "$status" -eq 0 ]
}

@test "validate brief rejects confirmed cause without owning-path proof" {
	_source_helper
	local body
	body="$(printf '## Reproducer\n**Symptom command**: aidevops pulse\n**Actual output**: cleanup failed with rc=2\n**Causal status**: confirmed\nThe root cause is a permissive guard in cleanup.sh:42.')"
	run validate_brief_has_reproducer "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"owning-path proof"* ]]
}

@test "validate brief accepts confirmed cause with owning-path proof" {
	_source_helper
	local body
	body="$(printf '## Reproducer\n**Symptom command**: aidevops pulse\n**Actual output**: cleanup failed with rc=2\n**Causal status**: confirmed\n**Owning-path proof**:\n- **Production entry point**: pulse.sh:42 starts merged-PR cleanup\n- **Call chain**: pulse_tick -> cleanup_merged_pr -> remove_worktree\n- **Integrated verification**: bash tests/test-cleanup.sh exercises pulse_tick with rc=2\nThe root cause is cleanup_merged_pr dropping the recovery return code.')"
	run validate_brief_has_reproducer "$body"
	[ "$status" -eq 0 ]
}

@test "validate brief accepts explicit unconfirmed investigation" {
	_source_helper
	local body
	body="$(printf '## Reproducer\n**Symptom command**: aidevops pulse\n**Actual output**: cleanup failed with rc=2\n**Causal status**: unconfirmed investigation\nA guard in cleanup.sh:42 is a suspected cause; causality is not established.')"
	run validate_brief_has_reproducer "$body"
	[ "$status" -eq 0 ]
}

@test "validate brief does not let unrelated investigation text bypass confirmed status" {
	_source_helper
	local body
	body="$(printf '## Reproducer\n**Symptom command**: aidevops pulse\n**Actual output**: cleanup failed with rc=2\n**Causal status**: confirmed\nThe prior investigation collected useful logs. The root cause is cleanup.sh:42.')"
	run validate_brief_has_reproducer "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"owning-path proof"* ]]
}

@test "diagnostics includes a supplied AI model" {
	_source_helper
	get_aidevops_version() { printf '%s\n' "test-version"; return 0; }
	get_latest_version() { printf '%s\n' "test-version"; return 0; }
	get_install_method() { printf '%s\n' "test"; return 0; }
	get_git_context() { printf '%s\n' "test (branch)"; return 0; }
	export AIDEVOPS_SIG_MODEL="openai/test-model"
	run gather_diagnostics
	[ "$status" -eq 0 ]
	[[ "$output" == *"**AI Model**: openai/test-model"* ]]
}

@test "diagnostics omits an unknown AI model" {
	_source_helper
	get_aidevops_version() { printf '%s\n' "test-version"; return 0; }
	get_latest_version() { printf '%s\n' "test-version"; return 0; }
	get_install_method() { printf '%s\n' "test"; return 0; }
	get_git_context() { printf '%s\n' "test (branch)"; return 0; }
	unset AIDEVOPS_SIG_MODEL
	run gather_diagnostics
	[ "$status" -eq 0 ]
	[[ "$output" != *"**AI Model**"* ]]
}

@test "check_recent_filing returns OK when no state file" {
	_source_helper
	local result
	result=$(check_recent_filing "my title" "my body")
	[[ "$result" == "OK" ]]
}

@test "record_filing then check_recent_filing returns DUPLICATE" {
	_source_helper
	local title="dedup: integration test"
	local body="Issue body content"

	record_filing "$title" "$body" 99999

	local result
	result=$(check_recent_filing "$title" "$body" || true)
	[[ "$result" == DUPLICATE:99999:* ]]
}

@test "cross-path dedup: body-with-trailer filed after body-plain returns DUPLICATE" {
	_source_helper
	local title="dedup: cross-path test"
	local body_plain="Issue body content"
	local body_with_trailer
	body_with_trailer="$(printf '%s\n\n---\n*Detected by framework-routing-helper in \`owner/repo\`.*' "$body_plain")"

	# Path A: file via /log-issue-aidevops (no trailer)
	record_filing "$title" "$body_plain" 10001

	# Path B: framework-routing-helper fires with trailer
	local result
	result=$(check_recent_filing "$title" "$body_with_trailer" || true)
	[[ "$result" == DUPLICATE:10001:* ]]
}

@test "cross-path dedup: body-with-sig filed after body-with-trailer returns DUPLICATE" {
	_source_helper
	local title="dedup: sig+trailer cross-path test"
	local body_plain="Issue body content"
	local body_with_trailer
	body_with_trailer="$(printf '%s\n\n---\n*Detected by framework-routing-helper in \`owner/repo\`.*' "$body_plain")"
	local body_with_sig_and_trailer
	body_with_sig_and_trailer="$(printf '%s\n<!-- aidevops:sig -->\nsig block' "$body_with_trailer")"

	# Path A: framework-routing-helper filed (body + trailer)
	record_filing "$title" "$body_with_trailer" 10002

	# Path B: same but body has sig footer too
	local result
	result=$(check_recent_filing "$title" "$body_with_sig_and_trailer" || true)
	[[ "$result" == DUPLICATE:10002:* ]]
}

@test "check_recent_filing returns OK after dedup window expires" {
	_source_helper
	local title="dedup: window expiry test"
	local body="Issue body content"
	local fp_file
	fp_file=$(_log_issue_fingerprint_file)

	# Inject an expired record (epoch 1 = far in the past)
	local fingerprint
	fingerprint=$(_compute_issue_fingerprint "$title" "$body")
	printf '{"hash":"%s","issue":77777,"filed_at":"2020-01-01T00:00:00Z","filed_epoch":1}\n' \
		"$fingerprint" >> "$fp_file"

	# Should NOT deduplicate — record is outside the window
	local result
	result=$(check_recent_filing "$title" "$body")
	[[ "$result" == "OK" ]]
}
