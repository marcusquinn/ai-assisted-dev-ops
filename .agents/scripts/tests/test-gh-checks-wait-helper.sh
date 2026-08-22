#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HELPER="${SCRIPT_DIR}/../gh-checks-wait-helper.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass_count=0
fail_count=0

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	pass_count=$((pass_count + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL: %s%s\n' "$name" "${detail:+ — $detail}"
	fail_count=$((fail_count + 1))
	return 0
}

assert_contains() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "missing ${needle}"
	fi
	return 0
}

write_fixture() {
	local directory="$1"
	local number="$2"
	local content="$3"
	mkdir -p "$directory"
	printf '%s\n' "$content" >"${directory}/poll-${number}.json"
	return 0
}

run_fixture_wait() {
	local fixture_dir="$1"
	shift
	AIDEVOPS_GH_CHECKS_FIXTURE_DIR="$fixture_dir" \
		AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 \
		AIDEVOPS_GH_CHECKS_TEST_HEAD="${AIDEVOPS_GH_CHECKS_TEST_HEAD_OVERRIDE-fixture-head}" \
		"$HELPER" wait 123 --repo example/repo --initial-interval 1 --max-interval 4 "$@"
	return $?
}

transition_dir="${TMPDIR_TEST}/transition"
write_fixture "$transition_dir" 1 '[{"name":"Complexity","workflow":"CI","state":"PENDING","bucket":"pending","link":"https://example.invalid/1"},{"name":"maintainer-gate","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
write_fixture "$transition_dir" 2 '[{"name":"Complexity","workflow":"CI","state":"PENDING","bucket":"pending","link":"https://example.invalid/1"},{"name":"maintainer-gate","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
write_fixture "$transition_dir" 3 '[{"name":"Complexity","workflow":"CI","state":"SUCCESS","bucket":"pass","link":"https://example.invalid/1"},{"name":"maintainer-gate","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'

transition_output=$(run_fixture_wait "$transition_dir")
assert_contains "wait prints initial state once" "CI wait started: pass=1 pending=1" "$transition_output"
assert_contains "wait prints state transition" "+ Complexity: pending -> pass" "$transition_output"
assert_contains "wait prints terminal success" "PASS: required checks completed" "$transition_output"
pending_count=$(printf '%s\n' "$transition_output" | grep -c '^  Complexity: pending$' || true)
[[ "$pending_count" -eq 1 ]] && pass "unchanged snapshot is not replayed" || fail "unchanged snapshot is not replayed" "count ${pending_count}"

empty_dir="${TMPDIR_TEST}/empty"
write_fixture "$empty_dir" 1 '[]'
empty_output=$(run_fixture_wait "$empty_dir")
assert_contains "no required checks is explicit terminal success" "PASS: verified no required checks; optional checks were not evaluated (use --all to wait for all checks)" "$empty_output"

all_checks_dir="${TMPDIR_TEST}/all-checks"
write_fixture "$all_checks_dir" 1 '[{"name":"Preview","workflow":"Deploy","state":"PENDING","bucket":"pending","link":""}]'
write_fixture "$all_checks_dir" 2 '[{"name":"Preview","workflow":"Deploy","state":"SUCCESS","bucket":"pass","link":""}]'
all_checks_output=$(run_fixture_wait "$all_checks_dir" --all)
assert_contains "all-check mode observes pending optional checks" "Preview: pending" "$all_checks_output"
assert_contains "all-check mode waits for the transition" "+ Preview: pending -> pass" "$all_checks_output"
assert_contains "all-check mode reports scoped terminal success" "PASS: all checks completed" "$all_checks_output"

all_empty_output=$(run_fixture_wait "$empty_dir" --all)
assert_contains "empty all-check selection is explicit terminal success" "PASS: verified no checks reported" "$all_empty_output"

live_bin="${TMPDIR_TEST}/live-bin"
mkdir -p "$live_bin"
cat >"${live_bin}/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	printf '%s\n' 'live-head'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo/pulls/123" ]]; then
	printf '%s\n' '{"number":123,"node_id":"PR_fixture","head":{"ref":"feature/test","sha":"0123456789abcdef0123456789abcdef01234567"}}'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
	if [[ "${GH_TEST_MODE:-no-required}" == "api-error" ]]; then
		printf '%s\n' 'HTTP 503: service unavailable' >&2
		exit 1
	fi
	printf '%s\n' '{"data":{"node":{"__typename":"PullRequest","statusCheckRollup":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"StatusContext","context":"optional","state":"SUCCESS","targetUrl":"","createdAt":"2026-08-01T00:00:00Z","description":"","isRequired":false}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}]}},"rateLimit":{"cost":1}}}'
	exit 0
fi
exit 1
STUB
chmod +x "${live_bin}/gh"

live_no_required_output=$(PATH="${live_bin}:$PATH" AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 \
	"$HELPER" wait 123 --repo example/repo --timeout 0 2>&1)
assert_contains "canonical no-required message is explicit terminal success" "PASS: verified no required checks; optional checks were not evaluated" "$live_no_required_output"

set +e
live_api_error_output=$(PATH="${live_bin}:$PATH" GH_TEST_MODE=api-error AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 \
	"$HELPER" wait 123 --repo example/repo --timeout 0 2>&1)
live_api_error_rc=$?
set -e
[[ "$live_api_error_rc" -eq 2 ]] && pass "exact-read API error remains indeterminate" || fail "exact-read API error remains indeterminate" "got ${live_api_error_rc}"
assert_contains "exact-read API error is diagnosed" "state unavailable" "$live_api_error_output"

mixed_skipping_dir="${TMPDIR_TEST}/mixed-skipping"
write_fixture "$mixed_skipping_dir" 1 '[{"name":"Required","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""},{"name":"Optional","workflow":"CI","state":"SKIPPED","bucket":"skipping","link":""}]'
mixed_skipping_output=$(run_fixture_wait "$mixed_skipping_dir")
assert_contains "pass plus skipping is terminal success" "PASS: required checks completed" "$mixed_skipping_output"

skipping_only_dir="${TMPDIR_TEST}/skipping-only"
write_fixture "$skipping_only_dir" 1 '[{"name":"Optional","workflow":"CI","state":"SKIPPED","bucket":"skipping","link":""}]'
skipping_only_output=$(run_fixture_wait "$skipping_only_dir")
assert_contains "skipping-only checks are terminal success" "PASS: required checks completed" "$skipping_only_output"

set +e
head_unavailable_output=$(AIDEVOPS_GH_CHECKS_TEST_HEAD_OVERRIDE='' run_fixture_wait "$empty_dir" 2>&1)
head_unavailable_rc=$?
set -e
[[ "$head_unavailable_rc" -eq 2 ]] && pass "unverified PR head is indeterminate" || fail "unverified PR head is indeterminate" "got ${head_unavailable_rc}"
assert_contains "unverified PR head is diagnosed" "PR head could not be verified" "$head_unavailable_output"

failure_dir="${TMPDIR_TEST}/failure"
write_fixture "$failure_dir" 1 '[{"name":"ShellCheck","workflow":"CI","state":"FAILURE","bucket":"fail","link":"https://example.invalid/failure"}]'
set +e
failure_output=$(run_fixture_wait "$failure_dir" 2>&1)
failure_rc=$?
set -e
[[ "$failure_rc" -eq 1 ]] && pass "terminal failure returns one" || fail "terminal failure returns one" "got ${failure_rc}"
assert_contains "terminal failure names failed check" "ShellCheck: fail" "$failure_output"
failure_link_count=$(printf '%s\n' "$failure_output" | grep -c 'https://example.invalid/failure' || true)
[[ "$failure_link_count" -eq 1 ]] && pass "failure link is emitted once" || fail "failure link is emitted once" "count ${failure_link_count}"

other_failure_dir="${TMPDIR_TEST}/other-failures"
write_fixture "$other_failure_dir" 1 '[{"name":"Cancelled","workflow":"CI","state":"CANCELLED","bucket":"cancel","link":""},{"name":"Unexpected","workflow":"CI","state":"UNKNOWN","bucket":"mystery","link":""},{"name":"Optional","workflow":"CI","state":"SKIPPED","bucket":"skipping","link":""}]'
set +e
other_failure_output=$(run_fixture_wait "$other_failure_dir" 2>&1)
other_failure_rc=$?
set -e
[[ "$other_failure_rc" -eq 1 ]] && pass "cancel and unknown buckets return one" || fail "cancel and unknown buckets return one" "got ${other_failure_rc}"
assert_contains "cancelled check is reported" "Cancelled: cancel" "$other_failure_output"
assert_contains "unknown bucket is reported" "Unexpected: mystery" "$other_failure_output"
skipping_detail_count=$(printf '%s\n' "$other_failure_output" | grep -c '^  Optional: skipping$' || true)
[[ "$skipping_detail_count" -eq 1 ]] && pass "skipped check is omitted from failure details" || fail "skipped check is omitted from failure details" "count ${skipping_detail_count}"

recovery_dir="${TMPDIR_TEST}/recovery"
write_fixture "$recovery_dir" 1 'not-json'
write_fixture "$recovery_dir" 2 '[{"name":"Recovered","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
recovery_output=$(run_fixture_wait "$recovery_dir" 2>&1)
assert_contains "API failure is visible" "state unavailable" "$recovery_output"
assert_contains "API recovery is visible" "API state recovered" "$recovery_output"
assert_contains "API recovery can reach success" "PASS: required checks completed" "$recovery_output"

timeout_dir="${TMPDIR_TEST}/timeout"
write_fixture "$timeout_dir" 1 '[{"name":"Slow","workflow":"CI","state":"PENDING","bucket":"pending","link":""}]'
set +e
timeout_output=$(run_fixture_wait "$timeout_dir" --timeout 0 2>&1)
timeout_rc=$?
set -e
[[ "$timeout_rc" -eq 8 ]] && pass "pending timeout preserves gh pending exit" || fail "pending timeout preserves gh pending exit" "got ${timeout_rc}"
assert_contains "pending timeout remains diagnostic" "TIMEOUT: required checks remain non-terminal" "$timeout_output"

heartbeat_dir="${TMPDIR_TEST}/heartbeat"
heartbeat_file="${TMPDIR_TEST}/heartbeat/state"
mkdir -p "$(dirname "$heartbeat_file")"
write_fixture "$heartbeat_dir" 1 '[{"name":"Immediate","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
AIDEVOPS_FULL_LOOP_HEARTBEAT_FILE="$heartbeat_file" run_fixture_wait "$heartbeat_dir" >/dev/null
[[ -s "$heartbeat_file" ]] && pass "wait updates out-of-context runtime heartbeat" || fail "wait updates out-of-context runtime heartbeat"

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
if [[ "$fail_count" -ne 0 ]]; then
	exit 1
fi
