#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-stats-quality-sweep-simplification-nmr.sh — regression guard for the
# quality-sweep simplification NMR trust boundary.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/t-sweep-nmr.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

CREATE_CALLS="${TMP}/create-calls.log"
COUNT_FILE="${TMP}/created-count.txt"
LOGFILE="${TMP}/pulse.log"
export LOGFILE

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local message="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  FAIL %s\n' "$name"
	[[ -n "$message" ]] && printf '       %s\n' "$message"
	return 0
}

print_info() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
log_verbose() { return 0; }
export -f print_info print_warning print_error print_success log_verbose

gh_create_issue() {
	printf '%s\n' "$*" >>"$CREATE_CALLS"
	printf 'https://github.com/test/repo/issues/123\n'
	return 0
}
export -f gh_create_issue

gh() {
	case "$*" in
	*"label create"*)
		return 0
		;;
	*"api graphql"*)
		printf '0\n'
		return 0
		;;
	*"issue list"*)
		if [[ -n "${EXISTING_CITED_FILE:-}" && "$*" == *"cited_file=${EXISTING_CITED_FILE}"* ]]; then
			printf '1\n'
		else
			printf '0\n'
		fi
		return 0
		;;
	esac
	return 0
}
export -f gh

mkdir -p "${TMP}/.config/aidevops"
cat >"${TMP}/.config/aidevops/repos.json" <<'JSON'
{"initialized_repos":[{"slug":"test/repo","maintainer":"maintainer"}]}
JSON
ORIGINAL_HOME="$HOME"
export HOME="$TMP"

# shellcheck source=../stats-quality-sweep.sh
SCRIPT_DIR="$SCRIPTS_DIR" source "${SCRIPTS_DIR}/stats-quality-sweep.sh" || {
	printf 'FATAL could not source stats-quality-sweep.sh\n'
	export HOME="$ORIGINAL_HOME"
	exit 1
}

make_sarif() {
	cat <<'JSON'
{"runs":[{"results":[
{"ruleId":"complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/foo.py"}}}]},
{"ruleId":"complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/foo.py"}}}]},
{"ruleId":"complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/foo.py"}}}]}
]}]}
JSON
	return 0
}

make_distributed_sarif() {
	cat <<'JSON'
{"runs":[{"results":[
{"ruleId":"complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/a.sh"}}}]},
{"ruleId":"returns","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/b.sh"}}}]},
{"ruleId":"nested-control-flow","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/c.sh"}}}]},
{"ruleId":"complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/d.sh"}}}]}
]}]}
JSON
	return 0
}

make_partially_unlocated_sarif() {
	cat <<'JSON'
{"runs":[{"results":[
{"ruleId":"metadata-only"},
{"ruleId":"empty-locations","locations":[]},
{"ruleId":"complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/foo.py"}}}]}
]}]}
JSON
	return 0
}

printf '\n[a] trusted repo writer skips NMR\n'
true >"$CREATE_CALLS"
true >"$COUNT_FILE"
qlty_section="caller-owned-section"
_gh_current_user_allows_repo_write() {
	AIDEVOPS_GH_WRITE_PERMISSION_USER="maintainer"
	AIDEVOPS_GH_WRITE_PERMISSION_LEVEL="admin"
	AIDEVOPS_GH_WRITE_PERMISSION_REASON="allowed"
	export AIDEVOPS_GH_WRITE_PERMISSION_USER AIDEVOPS_GH_WRITE_PERMISSION_LEVEL AIDEVOPS_GH_WRITE_PERMISSION_REASON
	return 0
}
_create_simplification_issues "test/repo" "$(make_sarif)" >"$COUNT_FILE"
if grep -q -- '--label needs-maintainer-review' "$CREATE_CALLS" 2>/dev/null; then
	fail "trusted-writer-no-nmr-label" "unexpected NMR label: $(cat "$CREATE_CALLS")"
else
	pass "trusted-writer-no-nmr-label"
fi
if grep -q -- '--label auto-dispatch' "$CREATE_CALLS" 2>/dev/null &&
	grep -q -- '--label quality-debt' "$CREATE_CALLS" 2>/dev/null; then
	pass "trusted-writer-autonomous-quality-labels"
else
	fail "trusted-writer-autonomous-quality-labels" "missing auto-dispatch or quality-debt: $(<"$CREATE_CALLS")"
fi
if grep -Fq -- '### Files Scope' "$CREATE_CALLS" 2>/dev/null &&
	grep -Fq -- "- EDIT: \`src/foo.py\`" "$CREATE_CALLS" 2>/dev/null; then
	pass "trusted-writer-autonomous-body-has-files-scope"
else
	fail "trusted-writer-autonomous-body-has-files-scope" "missing canonical Files Scope: $(<"$CREATE_CALLS")"
fi
if [[ "$(<"$COUNT_FILE")" == "1" ]]; then
	pass "simplification-count-stdout"
else
	fail "simplification-count-stdout" "expected count 1, got: $(<"$COUNT_FILE")"
fi
if [[ "${qlty_section:-}" == "caller-owned-section" ]]; then
	pass "simplification-no-caller-qlty-section-mutation"
else
	fail "simplification-no-caller-qlty-section-mutation" "caller qlty_section mutated to: ${qlty_section:-<unset>}"
fi

printf '\n[a.1] incomplete SARIF locations are ignored\n'
smell_files=$(_smell_files_from_sarif "$(make_partially_unlocated_sarif)")
if [[ "$smell_files" == $'1\tsrc/foo.py' ]]; then
	pass "incomplete-sarif-locations-ignored"
else
	fail "incomplete-sarif-locations-ignored" "expected only src/foo.py, got: ${smell_files:-<empty>}"
fi

printf '\n[a.2] optional logfile is nounset-safe\n'
if (unset LOGFILE; _create_simplification_issues "test/repo" '{}' >/dev/null) &&
	(unset LOGFILE; _create_simplification_issues "test/repo" "$(make_sarif)" 0 >/dev/null); then
	pass "optional-logfile-nounset-safe"
else
	fail "optional-logfile-nounset-safe" "LOGFILE fallback failed under set -u"
fi

printf '\n[b] unverified identity keeps NMR\n'
true >"$CREATE_CALLS"
true >"$COUNT_FILE"
qlty_section="caller-owned-section"
unset AIDEVOPS_GH_WRITE_PERMISSION_USER AIDEVOPS_GH_WRITE_PERMISSION_LEVEL AIDEVOPS_GH_WRITE_PERMISSION_REASON
_gh_current_user_allows_repo_write() {
	AIDEVOPS_GH_WRITE_PERMISSION_REASON="permission-lookup-failed:api-failure"
	export AIDEVOPS_GH_WRITE_PERMISSION_REASON
	return 1
}
_create_simplification_issues "test/repo" "$(make_sarif)" >"$COUNT_FILE"
if grep -q -- '--label needs-maintainer-review' "$CREATE_CALLS" 2>/dev/null; then
	pass "unverified-keeps-nmr-label"
else
	fail "unverified-keeps-nmr-label" "missing NMR label: $(cat "$CREATE_CALLS")"
fi
if [[ "$(<"$COUNT_FILE")" == "1" ]]; then
	pass "unverified-count-stdout"
else
	fail "unverified-count-stdout" "expected count 1, got: $(<"$COUNT_FILE")"
fi
if [[ "${qlty_section:-}" == "caller-owned-section" ]]; then
	pass "unverified-no-caller-qlty-section-mutation"
else
	fail "unverified-no-caller-qlty-section-mutation" "caller qlty_section mutated to: ${qlty_section:-<unset>}"
fi

printf '\n[c] distributed low-density debt covers exact deficit\n'
true >"$CREATE_CALLS"
true >"$COUNT_FILE"
unset EXISTING_CITED_FILE
_gh_current_user_allows_repo_write() { return 0; }
_create_simplification_issues "test/repo" "$(make_distributed_sarif)" "2" >"$COUNT_FILE"
if [[ "$(<"$COUNT_FILE")" == "2" ]]; then
	pass "distributed-one-smell-files-scheduled"
else
	fail "distributed-one-smell-files-scheduled" "expected 2 issues for deficit 2, got: $(<"$COUNT_FILE")"
fi
if grep -q 'actual=4 threshold=2 deficit=2' "$CREATE_CALLS" 2>/dev/null; then
	pass "worker-body-carries-threshold-evidence"
else
	fail "worker-body-carries-threshold-evidence" "missing structured threshold evidence"
fi

printf '\n[d] at-threshold state creates no repair issue\n'
true >"$CREATE_CALLS"
true >"$COUNT_FILE"
_create_simplification_issues "test/repo" "$(make_distributed_sarif)" "4" >"$COUNT_FILE"
if [[ "$(<"$COUNT_FILE")" == "0" && ! -s "$CREATE_CALLS" ]]; then
	pass "at-threshold-no-remediation"
else
	fail "at-threshold-no-remediation" "count=$(<"$COUNT_FILE") calls=$(<"$CREATE_CALLS")"
fi

printf '\n[e] existing file issue does not consume deficit budget\n'
true >"$CREATE_CALLS"
true >"$COUNT_FILE"
EXISTING_CITED_FILE="src/a.sh"
export EXISTING_CITED_FILE
_create_simplification_issues "test/repo" "$(make_distributed_sarif)" "2" >"$COUNT_FILE"
if [[ "$(<"$COUNT_FILE")" == "2" ]]; then
	pass "dedup-continues-to-next-file"
else
	fail "dedup-continues-to-next-file" "expected 2 new issues after one dedup, got: $(<"$COUNT_FILE")"
fi
if grep -q 'cited_file=src/a.sh' "$CREATE_CALLS" 2>/dev/null; then
	fail "dedup-does-not-recreate-existing-file" "existing file was recreated"
else
	pass "dedup-does-not-recreate-existing-file"
fi
unset EXISTING_CITED_FILE

export HOME="$ORIGINAL_HOME"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed.\n' "$TESTS_RUN"
	exit 0
fi
printf '%d of %d tests FAILED.\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
