#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-review-feedback-supersession-validator.sh — t3569/GH#23101 fixtures

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../pre-dispatch-validator-helper.sh"
PULSE_CORE="${SCRIPT_DIR}/../pulse-dispatch-core.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi

	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	GH_LOG="${TEST_ROOT}/gh.log"
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export GH_LOG
	export AIDEVOPS_SIG_CLI="test"
	export AIDEVOPS_SIG_CLI_VERSION="1"
	export AIDEVOPS_SIG_MODEL="test/model"
	export AIDEVOPS_SIG_TOKENS="0"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

write_gh_stub() {
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
set -euo pipefail

scenario="${STUB_SCENARIO:-}"
log_file="${GH_LOG:?}"

log_call() {
	printf '%s\n' "$*" >>"$log_file"
	return 0
}

arg_string="$*"
endpoint=""
for arg in "$@"; do
	case "$arg" in
	search/issues | repos/owner/repo | repos/owner/repo/*)
		endpoint="$arg"
		break
		;;
	esac
done

if [[ "${1:-}" == "api" && "$endpoint" == repos/owner/repo/issues/* && "$endpoint" != */comments ]]; then
	case "$arg_string" in
	*'.body // ""'*)
		case "$scenario" in
		source-clear | source-ambiguous | source-fetch-failure | duplicate-later | duplicate-canonical | duplicate-lookup-failure)
			printf '**Source PR**: #50\n\n## Files to modify\n- `.agents/scripts/review-hook.sh`\n\n## Finding\nAdd the event payload guard before worker launch.\n'
			;;
		footer-path-noise)
			printf '**Source PR**: #50\n\n**File**: `.agents/scripts/issue-sync-helper.sh`\n\nAdd an option guard before worker launch.\n\n<!-- aidevops:sig -->\n---\n[aidevops.sh](https://aidevops.sh) automated scan.\n'
			;;
		quoted-path)
			printf '> > - `.agents/scripts/review-hook.sh:217`\n> above already architecture before dispatch\n'
			;;
		basename-only)
			printf '## Finding\n\n`review-hook.sh` needs an event payload guard before dispatch.\n'
			;;
		marker-only-duplicate | duplicate-current-absent)
			printf '<!-- aidevops:generator=review-followup source_pr=50 fingerprint=source-pr-50 -->\n\n## Files to modify\n- `.agents/scripts/review-hook.sh`\n'
			;;
		malformed-source-clear)
			printf '**Source PR**: pending\n\n## Files to modify\n- `.agents/scripts/review-hook.sh`\n\n## Finding\nAdd the event payload guard before worker launch.\n'
			;;
		no-file)
			printf '**Source PR**: #50\n\n## Finding\nAdd the event payload guard before worker launch.\n'
			;;
		*)
			printf '## Files to modify\n- `.agents/scripts/review-hook.sh`\n\n## Finding\nAdd the event payload guard before worker launch.\n'
			;;
		esac
		;;
	*'@tsv'*)
		case "$scenario" in
		duplicate-later | duplicate-canonical | duplicate-lookup-failure | marker-only-duplicate | duplicate-current-absent)
			printf '2026-05-02T10:00:00Z\tReview followup: PR #50 — event payload guard\treview-followup,source:review-scanner,tier:standard\n'
			;;
		source-clear | source-ambiguous | source-fetch-failure | no-file)
			printf '2026-05-02T10:00:00Z\treview-feedback: event payload guard\tquality-debt,source:review-feedback,tier:thinking\n'
			;;
		malformed-source-clear)
			printf '2026-05-02T10:00:00Z\tReview followup: PR #50 — event payload guard\tquality-debt,source:review-feedback,tier:thinking\n'
			;;
		*)
			printf '2026-05-01T10:00:00Z\treview-feedback: event payload guard\tquality-debt,source:review-feedback,tier:thinking\n'
			;;
		esac
		;;
	*'join(",")'*)
		printf 'quality-debt,source:review-feedback,tier:thinking\n'
		;;
	*)
		printf '{}\n'
		;;
	esac
	exit 0
fi

if [[ "${1:-}" == "api" && "$endpoint" == "repos/owner/repo" ]]; then
	printf 'false\n'
	exit 0
fi

if [[ "${1:-}" == "api" && "$endpoint" == "repos/owner/repo/issues/100/comments" ]]; then
	printf '0\n'
	exit 0
fi

if [[ "${1:-}" == "api" && "$endpoint" == "search/issues" ]]; then
	case "$scenario" in
	precreation-search-failure) exit 1 ;;
	clear) printf '200\n' ;;
	direct-reference) printf '205\n' ;;
	ambiguous) printf '201\n' ;;
	source-clear) printf '200\n' ;;
	malformed-source-clear) printf '200\n' ;;
	source-ambiguous) printf '201\n' ;;
	source-fetch-failure) printf '200\n' ;;
	no-file) printf '200\n' ;;
	footer-path-noise) printf '204\n' ;;
	quoted-path | basename-only) printf '200\n' ;;
	none) printf '' ;;
	before) printf '203\n' ;;
	*) printf '' ;;
	esac
	exit 0
fi

if [[ "${1:-}" == "api" && "$endpoint" == repos/owner/repo/pulls/* && "$endpoint" != */files ]]; then
	pr_number="${endpoint##*/}"
	if [[ "$pr_number" == "50" ]]; then
		if [[ "$scenario" == "source-fetch-failure" ]]; then
			exit 1
		fi
		case "$arg_string" in
		*'join("|")'*) printf 'closed|2026-05-01T09:30:00Z|2026-05-01T09:30:00Z\n' ;;
		*) printf '2026-05-01T09:30:00Z\n' ;;
		esac
		exit 0
	fi
	case "$pr_number" in
	200)
		printf '2026-05-01T11:00:00Z\tfix event payload guard\tAdds a guard for event payload handling.\n'
		;;
	201)
		printf '2026-05-01T11:00:00Z\trefactor review hook logging\tRenames local variables only.\n'
		;;
	203)
		printf '2026-05-01T09:00:00Z\tfix event payload guard\tAdds a guard for event payload handling.\n'
		;;
	204)
		printf '2026-05-01T11:00:00Z\tfix worker launch guard\tAdds an option guard before worker launch.\n'
		;;
	205)
		printf '2026-05-01T11:00:00Z\tGH#100: fix event payload guard\tResolves #100 with the event payload guard.\n'
		;;
	*)
		printf '\t\t\n'
		;;
	esac
	exit 0
fi

if [[ "${1:-}" == "api" && "$endpoint" == repos/owner/repo/pulls/*/files ]]; then
	pr_number="${endpoint%/files}"
	pr_number="${pr_number##*/}"
	case "$arg_string" in
	*'.filename'*)
		case "$pr_number" in
		200 | 201 | 203 | 205) printf '.agents/scripts/review-hook.sh\n' ;;
		204) printf 'aidevops.sh\n' ;;
		*) printf '' ;;
		esac
		;;
	*)
		case "$pr_number" in
		200 | 203 | 205) printf '.agents/scripts/review-hook.sh\n+ add event payload guard before dispatch\n' ;;
		201) printf '.agents/scripts/review-hook.sh\n+ rename log_context to context_label\n' ;;
		204) printf 'aidevops.sh\n+ add option guard before worker launch\n' ;;
		*) printf '' ;;
		esac
		;;
	esac
	exit 0
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
	case "$scenario" in
	duplicate-later)
		printf '[{"number":99,"title":"Review followup: PR #50 — first","body":"**Source PR**: #50"},{"number":100,"title":"Review followup: PR #50 — duplicate","body":"**Source PR**: #50"}]\n'
		;;
	duplicate-canonical)
		printf '[{"number":100,"title":"Review followup: PR #50 — first","body":"**Source PR**: #50"},{"number":101,"title":"Review followup: PR #50 — duplicate","body":"**Source PR**: #50"}]\n'
		;;
	duplicate-lookup-failure)
		exit 1
		;;
	marker-only-duplicate)
		printf '[{"number":99,"title":"edited title","body":"<!-- aidevops:generator=review-followup source_pr=50 fingerprint=source-pr-50 -->"},{"number":100,"title":"another edited title","body":"<!-- aidevops:generator=review-followup source_pr=50 fingerprint=source-pr-50 -->"}]\n'
		;;
	duplicate-current-absent)
		printf '[{"number":99,"title":"edited title","body":"<!-- aidevops:generator=review-followup source_pr=50 fingerprint=source-pr-50 -->"}]\n'
		;;
	*)
		printf '[{"number":100,"title":"Review followup: PR #50 — current","body":"**Source PR**: #50"}]\n'
		;;
	esac
	exit 0
fi

if [[ "${1:-}" == "issue" ]]; then
	log_call "$*"
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

run_validator_case() {
	local scenario="$1"
	local expected_rc="$2"
	local test_name="$3"
	local output_file="${TEST_ROOT}/${scenario}.out"
	local rc=0

	: >"$GH_LOG"
	export STUB_SCENARIO="$scenario"
	"$HELPER_SCRIPT" validate "100" "owner/repo" >"$output_file" 2>&1 || rc=$?

	if [[ "$rc" -eq "$expected_rc" ]]; then
		print_result "${test_name}: exit ${expected_rc}" 0
	else
		print_result "${test_name}: exit ${expected_rc}" 1 "got ${rc}; output=$(tr '\n' ' ' <"$output_file")"
	fi
	return 0
}

assert_log_contains() {
	local test_name="$1"
	local expected="$2"

	if grep -qF "$expected" "$GH_LOG"; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "missing log entry: ${expected}"
	fi
	return 0
}

assert_log_not_contains() {
	local test_name="$1"
	local unexpected="$2"

	if grep -qF "$unexpected" "$GH_LOG"; then
		print_result "$test_name" 1 "unexpected log entry: ${unexpected}"
	else
		print_result "$test_name" 0
	fi
	return 0
}

test_keyword_same_file_fix_is_ambiguous() {
	run_validator_case "clear" 0 "keyword-only same-file supersession"
	assert_log_not_contains "keyword-only same-file supersession does not close" "issue close 100 --repo owner/repo --reason not planned"
	assert_log_contains "keyword-only same-file supersession posts decision comment" "issue comment 100 --repo owner/repo --body"
	return 0
}

test_direct_issue_reference_closes() {
	run_validator_case "direct-reference" 10 "direct issue reference supersession"
	assert_log_contains "direct issue reference closes issue" "issue close 100 --repo owner/repo --reason not planned"
	return 0
}

test_ambiguous_same_file_unrelated_change() {
	run_validator_case "ambiguous" 0 "ambiguous same-file unrelated change"
	assert_log_not_contains "ambiguous same-file change does not close" "issue close 100 --repo owner/repo --reason not planned"
	assert_log_contains "ambiguous same-file change posts decision comment" "issue comment 100 --repo owner/repo --body"
	return 0
}

test_source_pr_window_keyword_match_is_ambiguous() {
	run_validator_case "source-clear" 0 "source PR window keyword-only supersession"
	assert_log_not_contains "source PR window keyword-only match does not close" "issue close 100 --repo owner/repo --reason not planned"
	assert_log_contains "source PR window keyword-only match posts decision comment" "issue comment 100 --repo owner/repo --body"
	return 0
}

test_malformed_source_pr_title_fallback_is_ambiguous() {
	run_validator_case "malformed-source-clear" 0 "malformed source PR title fallback"
	assert_log_not_contains "malformed source PR title fallback does not close" "issue close 100 --repo owner/repo --reason not planned"
	assert_log_contains "malformed source PR title fallback posts decision comment" "issue comment 100 --repo owner/repo --body"
	return 0
}

test_source_pr_window_ambiguous_fails_open() {
	run_validator_case "source-ambiguous" 0 "source PR window ambiguous same-file change"
	assert_log_not_contains "source PR ambiguous change does not close" "issue close 100 --repo owner/repo --reason not planned"
	assert_log_contains "source PR ambiguous change posts decision comment" "issue comment 100 --repo owner/repo --body"
	return 0
}

test_source_pr_fetch_failure_falls_back() {
	run_validator_case "source-fetch-failure" 0 "source PR fetch failure falls back"
	assert_log_not_contains "source PR fetch failure does not use pre-issue candidate" "issue close 100 --repo owner/repo --reason not planned"
	return 0
}

test_no_file_finding_skips_supersession() {
	run_validator_case "no-file" 0 "no cited file paths skips supersession"
	assert_log_not_contains "no-file finding does not close" "issue close 100 --repo owner/repo --reason not planned"
	return 0
}

test_signature_footer_path_is_not_target_file() {
	run_validator_case "footer-path-noise" 0 "signature footer path is ignored"
	assert_log_not_contains "signature footer does not create false supersession" "issue close 100 --repo owner/repo --reason not planned"
	return 0
}

test_blockquoted_path_is_not_target_file() {
	run_validator_case "quoted-path" 0 "blockquoted path is ignored"
	assert_log_not_contains "blockquoted path does not create false supersession" "issue close 100 --repo owner/repo --reason not planned"
	assert_log_not_contains "blockquoted path does not create ambiguous candidate" "issue comment 100 --repo owner/repo --body"
	return 0
}

test_bare_basename_is_not_file_identity() {
	run_validator_case "basename-only" 0 "bare basename is ignored"
	assert_log_not_contains "bare basename does not create false supersession" "issue close 100 --repo owner/repo --reason not planned"
	assert_log_not_contains "bare basename does not create ambiguous candidate" "issue comment 100 --repo owner/repo --body"
	return 0
}

test_no_matching_pr() {
	run_validator_case "none" 0 "no matching merged PR"
	assert_log_not_contains "no matching PR does not close" "issue close 100 --repo owner/repo --reason not planned"
	assert_log_not_contains "no matching PR does not comment" "issue comment 100 --repo owner/repo --body"
	return 0
}

test_merged_pr_before_issue_creation() {
	run_validator_case "before" 0 "merged PR before issue creation"
	assert_log_not_contains "pre-issue merged PR does not close" "issue close 100 --repo owner/repo --reason not planned"
	return 0
}

test_precreation_source_pr_window() {
	local output_file="${TEST_ROOT}/precreation.out"
	local rc=0
	export STUB_SCENARIO="source-clear"
	printf '%s\n' '## Files to modify' "- \`.agents/scripts/review-hook.sh\`" 'Add the event payload guard before worker launch.' |
		"$HELPER_SCRIPT" check-review-supersession owner/repo 50 >"$output_file" 2>&1 || rc=$?
	if [[ "$rc" -eq 10 ]] && grep -qF 'SUPERSEDED_BY_PR=200' "$output_file"; then
		print_result "precreation supersession uses source PR merge window" 0
	else
		print_result "precreation supersession uses source PR merge window" 1 "rc=${rc}; output=$(tr '\n' ' ' <"$output_file")"
	fi
	return 0
}

test_precreation_api_uncertainty_fails_closed() {
	local output_file="${TEST_ROOT}/precreation-uncertain.out"
	local rc=0
	export STUB_SCENARIO="precreation-search-failure"
	printf '%s\n' '## Files to modify' "- \`.agents/scripts/review-hook.sh\`" 'Add the event payload guard before worker launch.' |
		"$HELPER_SCRIPT" check-review-supersession owner/repo 50 >"$output_file" 2>&1 || rc=$?
	if [[ "$rc" -eq 20 ]]; then
		print_result "precreation API uncertainty fails closed" 0
	else
		print_result "precreation API uncertainty fails closed" 1 "rc=${rc}; output=$(tr '\n' ' ' <"$output_file")"
	fi
	return 0
}

test_legacy_duplicate_noncanonical_closes() {
	run_validator_case "duplicate-later" 10 "legacy duplicate noncanonical issue"
	assert_log_contains "legacy duplicate closes later issue" "issue close 100 --repo owner/repo --reason not planned"
	return 0
}

test_legacy_duplicate_canonical_does_not_mutate_peers() {
	run_validator_case "duplicate-canonical" 0 "legacy duplicate canonical issue"
	assert_log_not_contains "canonical issue leaves later duplicate for its own validator" "issue close 101 --repo owner/repo --reason not planned"
	return 0
}

test_legacy_duplicate_lookup_fails_closed() {
	run_validator_case "duplicate-lookup-failure" 30 "legacy duplicate lookup uncertainty"
	assert_log_not_contains "lookup uncertainty does not close without evidence" "issue close 100"
	return 0
}

test_explicit_fingerprint_survives_title_and_label_drift() {
	run_validator_case "marker-only-duplicate" 10 "explicit review-followup fingerprint"
	assert_log_contains "explicit fingerprint closes noncanonical current issue" "issue close 100 --repo owner/repo --reason not planned"
	return 0
}

test_current_issue_absent_from_enumeration_fails_closed() {
	run_validator_case "duplicate-current-absent" 30 "current issue absent from duplicate enumeration"
	assert_log_not_contains "absent current issue does not mutate peers" "issue close 99"
	return 0
}

test_pulse_blocks_duplicate_lookup_uncertainty() {
	# shellcheck disable=SC2016 # Match literal shell source expressions.
	if grep -qF "if [[ \"\$_validator_rc\" -eq 30 ]]" "$PULSE_CORE" &&
		grep -qF '$_review_followup_validator_required" -eq 1 && "$_validator_rc" -ne 0' "$PULSE_CORE" &&
		grep -qF 'predispatch_validator_uncertain' "$PULSE_CORE" &&
		grep -qF 'return 20' "$PULSE_CORE"; then
		print_result "pulse blocks all required review-followup validator failures and releases its claim" 0
	else
		print_result "pulse blocks all required review-followup validator failures and releases its claim" 1
	fi
	return 0
}

main() {
	printf 'Running review-feedback supersession validator tests (t3569, GH#23101)...\n\n'

	if [[ ! -x "$HELPER_SCRIPT" ]]; then
		printf 'ERROR: helper script not executable: %s\n' "$HELPER_SCRIPT" >&2
		exit 1
	fi

	setup_test_env
	write_gh_stub
	test_keyword_same_file_fix_is_ambiguous
	test_direct_issue_reference_closes
	test_ambiguous_same_file_unrelated_change
	test_source_pr_window_keyword_match_is_ambiguous
	test_malformed_source_pr_title_fallback_is_ambiguous
	test_source_pr_window_ambiguous_fails_open
	test_source_pr_fetch_failure_falls_back
	test_no_file_finding_skips_supersession
	test_signature_footer_path_is_not_target_file
	test_blockquoted_path_is_not_target_file
	test_bare_basename_is_not_file_identity
	test_no_matching_pr
	test_merged_pr_before_issue_creation
	test_precreation_source_pr_window
	test_precreation_api_uncertainty_fails_closed
	test_legacy_duplicate_noncanonical_closes
	test_legacy_duplicate_canonical_does_not_mutate_peers
	test_legacy_duplicate_lookup_fails_closed
	test_explicit_fingerprint_survives_title_and_label_drift
	test_current_issue_absent_from_enumeration_fails_closed
	test_pulse_blocks_duplicate_lookup_uncertainty
	teardown_test_env

	printf '\n%d test(s) run, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
