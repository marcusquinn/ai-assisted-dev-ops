#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-circuit-breaker-meta-filer.sh — t3076 regression guard.
#
# Asserts circuit-breaker-meta-filer.sh:
#   (1) files a meta-issue with a blocked-by:#<meta> link on the original
#       when a breaker trips for the first time
#   (2) is idempotent — second trip on the same original returns the
#       existing meta-issue URL without creating a duplicate
#   (3) honours AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE=1 as a no-op
#   (4) validates --breaker as one of {cost,no_work}
#   (5) unblock-on-merge removes blocked-by:#<meta> from the original and
#       restores status:available when no other current blockers remain
#
# Modeled on test-cost-circuit-breaker.sh (t2007).

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
META_FILER="${TEST_SCRIPTS_DIR}/circuit-breaker-meta-filer.sh"

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

# Sandbox HOME so config/state writes are side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

# =============================================================================
# Stub harness — fake `gh` CLI that returns canned responses and logs all
# invocations so we can assert call counts and operations.
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin"
STUB_LOG="${TEST_ROOT}/gh-stub.log"
ISSUE_CREATE_COUNT_FILE="${TEST_ROOT}/issue-create-count"
mkdir -p "$STUB_DIR"
printf '0' >"$ISSUE_CREATE_COUNT_FILE"

# Fixture state files — the stub reads these to vary behaviour per scenario.
FIXTURE_COMMENTS_JSON="${TEST_ROOT}/fixture-comments.json"
FIXTURE_META_BODY="${TEST_ROOT}/fixture-meta-body"
FIXTURE_HAS_FRAMEWORK_SOURCE="${TEST_ROOT}/fixture-has-framework-source"
FIXTURE_REPO_PRIVATE="${TEST_ROOT}/fixture-repo-private"
FIXTURE_BLOCKED_BY_COUNT="${TEST_ROOT}/fixture-blocked-by-count"
echo '[]' >"$FIXTURE_COMMENTS_JSON"
echo '' >"$FIXTURE_META_BODY"
printf '1' >"$FIXTURE_HAS_FRAMEWORK_SOURCE"
printf 'false' >"$FIXTURE_REPO_PRIVATE"
printf '0' >"$FIXTURE_BLOCKED_BY_COUNT"

write_stub_gh() {
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub gh for test-circuit-breaker-meta-filer.sh
echo "\$@" >>"${STUB_LOG}"

# gh issue create --repo SLUG --title T --body B --label L
if [[ "\$1" == "issue" && "\$2" == "create" ]]; then
	repo='marcusquinn/aidevops'
	while [[ "\$#" -gt 0 ]]; do
		if [[ "\$1" == "--repo" ]]; then
			repo="\${2:-\$repo}"
			shift 2
			continue
		fi
		shift
	done
	# Increment counter so we can assert idempotency
	cnt=\$(cat "${ISSUE_CREATE_COUNT_FILE}")
	printf '%s' "\$((cnt + 1))" >"${ISSUE_CREATE_COUNT_FILE}"
	echo "https://github.com/\${repo}/issues/99999"
	exit 0
fi

# gh api repos/SLUG/issues/N/comments --paginate
if [[ "\$1" == "api" ]]; then
	case "\$2" in
		/repos/*/labels*)
			printf 'status:available\t0e8a16\tTask is available for claiming\n'
			printf 'status:queued\tfbca04\tWorker dispatched, not yet started\n'
			printf 'status:claimed\tf9d0c4\tInteractive session claimed this task\n'
			printf 'status:in-progress\t1d76db\tWorker actively running\n'
			printf 'status:in-review\t5319e7\tPR open, awaiting review/merge\n'
			printf 'status:done\t6f42c1\tTask is complete\n'
			printf 'status:blocked\td93f0b\tWaiting on blocker task\n'
			exit 0 ;;
		/repos/*/issues/*)
			exit 1 ;;
		repos/*/contents/.agents/scripts/circuit-breaker-meta-filer.sh*)
			if [[ "\$(cat "${FIXTURE_HAS_FRAMEWORK_SOURCE}")" == "1" ]]; then
				echo '{"type":"file"}'
				exit 0
			fi
			echo '{"message":"Not Found"}' >&2
			exit 1 ;;
		repos/*/issues/*/comments)
			cat "${FIXTURE_COMMENTS_JSON}" 2>/dev/null || echo '[]'
			exit 0 ;;
		repos/*/issues/*)
			# gh api repos/SLUG/issues/N --jq '.body'
			cat "${FIXTURE_META_BODY}" 2>/dev/null || echo ''
			exit 0 ;;
		repos/*)
			cat "${FIXTURE_REPO_PRIVATE}" 2>/dev/null || echo 'false'
			exit 0 ;;
		user)
			echo '{"login":"test-runner"}'
			exit 0 ;;
		*)
			echo '{}'
			exit 0 ;;
	esac
fi

# gh issue comment N --repo SLUG --body B
if [[ "\$1" == "issue" && "\$2" == "comment" ]]; then
	exit 0
fi

# gh issue view N --json labels --jq ...
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	cat "${FIXTURE_BLOCKED_BY_COUNT}"
	exit 0
fi

# gh issue edit N --repo SLUG ...
if [[ "\$1" == "issue" && "\$2" == "edit" ]]; then
	exit 0
fi

# gh label list / create
if [[ "\$1" == "label" ]]; then
	[[ "\$2" == "list" ]] && echo '[]'
	exit 0
fi

exit 0
STUB
	chmod +x "${STUB_DIR}/gh"
	return 0
}

write_stub_gh

# Stub gh-signature-helper.sh so signature footer call doesn't blow up
mkdir -p "${HOME}/.aidevops/agents/scripts"
cat >"${STUB_DIR}/gh-signature-helper.sh" <<'EOF'
#!/usr/bin/env bash
# Minimal stub: emit a canonical sig footer marker
[[ "${1:-}" == "footer" ]] && printf '\n\n<!-- aidevops:sig --> stub footer\n'
exit 0
EOF
chmod +x "${STUB_DIR}/gh-signature-helper.sh"

# Prepend the stub dir so the meta-filer picks up our stub gh and sig helper
export PATH="${STUB_DIR}:${PATH}"

# Minimal pulse log so the forensics block has something to slice
PULSE_LOG="${HOME}/.aidevops/logs/pulse.log"
export PULSE_LOG
{
	echo "[2026-04-30 00:00:00] [dispatch_with_dedup] (t2117) Dispatch deferred for #21840 in marcusquinn/aidevops: FOOTPRINT_OVERLAP"
	echo "[2026-04-30 00:01:00] [worker-lifecycle][t2769] no_work breaker armed for #21840 (count=4)"
} >"$PULSE_LOG"

# =============================================================================
# Helper to reset stub state between scenarios
# =============================================================================
reset_stubs() {
	: >"$STUB_LOG"
	printf '0' >"$ISSUE_CREATE_COUNT_FILE"
	echo '[]' >"$FIXTURE_COMMENTS_JSON"
	echo '' >"$FIXTURE_META_BODY"
	printf '1' >"$FIXTURE_HAS_FRAMEWORK_SOURCE"
	printf 'false' >"$FIXTURE_REPO_PRIVATE"
	printf '0' >"$FIXTURE_BLOCKED_BY_COUNT"
	return 0
}

count_issue_creates() {
	cat "$ISSUE_CREATE_COUNT_FILE"
	return 0
}

# =============================================================================
# Test 1: First trip files a meta-issue
# =============================================================================
reset_stubs

OUT=$("$META_FILER" file \
	--issue 21840 --repo marcusquinn/aidevops \
	--breaker no_work --failure-count 4 \
	--reason "FOOTPRINT_OVERLAP with #21818" 2>&1)
RC=$?

# Assert: exit 0
if [[ "$RC" -eq 0 ]]; then
	print_result "first-trip: exit 0" 0
else
	print_result "first-trip: exit 0" 1 "got rc=$RC, output: $OUT"
fi

# Assert: meta URL printed on stdout
if printf '%s' "$OUT" | tail -1 | grep -qE 'github\.com/.+/issues/[0-9]+'; then
	print_result "first-trip: prints meta-issue URL" 0
else
	print_result "first-trip: prints meta-issue URL" 1 "stdout: $OUT"
fi

# Assert: exactly one issue created
CREATE_COUNT=$(count_issue_creates)
if [[ "$CREATE_COUNT" == "1" ]]; then
	print_result "first-trip: created exactly 1 issue" 0
else
	print_result "first-trip: created exactly 1 issue" 1 "got count=$CREATE_COUNT"
fi

# Assert: no_work generated briefs include the stale-recovery path and its
# dedicated regression test, so workers investigate the relevant false-positive
# route before changing generic exit-classifier or breaker code.
if grep -q 'dispatch-dedup-stale.sh::_is_stale_assignment' "$STUB_LOG"; then
	print_result "first-trip: no_work guidance names stale assignment path" 0
else
	print_result "first-trip: no_work guidance names stale assignment path" 1 "stub log: $(cat "$STUB_LOG")"
fi

if grep -q 'test-dispatch-dedup-stale-pagination.sh' "$STUB_LOG"; then
	print_result "first-trip: no_work verification includes stale pagination test" 0
else
	print_result "first-trip: no_work verification includes stale pagination test" 1 "stub log: $(cat "$STUB_LOG")"
fi

if grep -q 'meta blocker label that points from the original issue to this meta-issue' "$STUB_LOG" \
	&& ! grep -Fq "meta \`blocked-by\` label from #21840" "$STUB_LOG"; then
	print_result "first-trip: acceptance describes meta blocker unambiguously" 0
else
	print_result "first-trip: acceptance describes meta blocker unambiguously" 1 "stub log: $(cat "$STUB_LOG")"
fi

# =============================================================================
# Test 1b: Public app repos without framework sources route metas to aidevops
# =============================================================================
reset_stubs
printf '0' >"$FIXTURE_HAS_FRAMEWORK_SOURCE"
printf 'false' >"$FIXTURE_REPO_PRIVATE"

OUT=$("$META_FILER" file \
	--issue 4003 --repo exampleorg/examplerepo \
	--breaker no_work --failure-count 3 \
	--reason "worker canary preflight failed before worktree pre-creation" 2>&1)
RC=$?

if [[ "$RC" -eq 0 ]]; then
	print_result "cross-repo: exit 0" 0
else
	print_result "cross-repo: exit 0" 1 "got rc=$RC, output: $OUT"
fi

if printf '%s' "$OUT" | tail -1 | grep -q 'github.com/marcusquinn/aidevops/issues/99999'; then
	print_result "cross-repo: files meta in framework repo" 0
else
	print_result "cross-repo: files meta in framework repo" 1 "stdout: $OUT"
fi

if grep -qE 'issue create --repo marcusquinn/aidevops' "$STUB_LOG"; then
	print_result "cross-repo: create call targets framework repo" 0
else
	print_result "cross-repo: create call targets framework repo" 1 "stub log: $(cat "$STUB_LOG")"
fi

if grep -qE 'issue edit 4003 --repo exampleorg/examplerepo .*--add-label status:blocked .*--add-label blocked-by:marcusquinn/aidevops#99999' "$STUB_LOG" &&
	! grep -q -- '--add-label needs-maintainer-review' "$STUB_LOG"; then
	print_result "cross-repo: original gets structural block and full blocked-by label" 0
else
	print_result "cross-repo: original gets structural block and full blocked-by label" 1 "stub log: $(cat "$STUB_LOG")"
fi

if grep -q 'circuit-breaker-meta-filed:marcusquinn/aidevops#99999' "$STUB_LOG"; then
	print_result "cross-repo: marker records full meta ref" 0
else
	print_result "cross-repo: marker records full meta ref" 1 "stub log: $(cat "$STUB_LOG")"
fi

# =============================================================================
# Test 2: Idempotency — second trip with marker present returns existing
# =============================================================================
reset_stubs
# Simulate an existing marker comment from a prior trip
cat >"$FIXTURE_COMMENTS_JSON" <<'EOF'
[{"body":"<!-- circuit-breaker-meta-filed:#42424 -->\n## prior trip"}]
EOF

OUT=$("$META_FILER" file \
	--issue 21840 --repo marcusquinn/aidevops \
	--breaker no_work --failure-count 5 \
	--reason "second trip" 2>&1)
RC=$?

if [[ "$RC" -eq 0 ]]; then
	print_result "idempotent: exit 0" 0
else
	print_result "idempotent: exit 0" 1 "rc=$RC"
fi

CREATE_COUNT=$(count_issue_creates)
if [[ "$CREATE_COUNT" == "0" ]]; then
	print_result "idempotent: NO new issue created on second trip" 0
else
	print_result "idempotent: NO new issue created on second trip" 1 "got count=$CREATE_COUNT"
fi

if printf '%s' "$OUT" | tail -1 | grep -q '/issues/42424'; then
	print_result "idempotent: returns existing meta-issue URL (#42424)" 0
else
	print_result "idempotent: returns existing meta-issue URL (#42424)" 1 "stdout: $OUT"
fi

# =============================================================================
# Test 2b: Idempotency handles cross-repo markers
# =============================================================================
reset_stubs
printf '0' >"$FIXTURE_HAS_FRAMEWORK_SOURCE"
printf 'false' >"$FIXTURE_REPO_PRIVATE"
cat >"$FIXTURE_COMMENTS_JSON" <<'EOF'
[{"body":"<!-- circuit-breaker-meta-filed:marcusquinn/aidevops#51515 -->\n## prior cross-repo trip"}]
EOF

OUT=$("$META_FILER" file \
	--issue 4003 --repo exampleorg/examplerepo \
	--breaker no_work --failure-count 4 \
	--reason "second cross-repo trip" 2>&1)
RC=$?

if [[ "$RC" -eq 0 ]]; then
	print_result "idempotent-cross-repo: exit 0" 0
else
	print_result "idempotent-cross-repo: exit 0" 1 "rc=$RC"
fi

CREATE_COUNT=$(count_issue_creates)
if [[ "$CREATE_COUNT" == "0" ]]; then
	print_result "idempotent-cross-repo: NO new issue created" 0
else
	print_result "idempotent-cross-repo: NO new issue created" 1 "got count=$CREATE_COUNT"
fi

if printf '%s' "$OUT" | tail -1 | grep -q 'github.com/marcusquinn/aidevops/issues/51515'; then
	print_result "idempotent-cross-repo: returns existing framework URL" 0
else
	print_result "idempotent-cross-repo: returns existing framework URL" 1 "stdout: $OUT"
fi

# =============================================================================
# Test 3: Disable env var no-ops
# =============================================================================
reset_stubs

AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE=1 "$META_FILER" file \
	--issue 21840 --repo marcusquinn/aidevops \
	--breaker cost --failure-count 3 \
	--tier standard --spent 50000 --budget 30000 >/dev/null 2>&1
RC=$?

CREATE_COUNT=$(count_issue_creates)
if [[ "$RC" -eq 0 && "$CREATE_COUNT" == "0" ]]; then
	print_result "disable env var: no-op exit 0" 0
else
	print_result "disable env var: no-op exit 0" 1 "rc=$RC count=$CREATE_COUNT"
fi

# =============================================================================
# Test 4: Argument validation
# =============================================================================
reset_stubs

"$META_FILER" file \
	--issue 21840 --repo marcusquinn/aidevops \
	--breaker INVALID --failure-count 1 >/dev/null 2>&1
RC=$?
if [[ "$RC" -eq 1 ]]; then
	print_result "validation: rejects invalid --breaker" 0
else
	print_result "validation: rejects invalid --breaker" 1 "expected rc=1, got rc=$RC"
fi

"$META_FILER" file --repo marcusquinn/aidevops --breaker cost \
	--failure-count 1 >/dev/null 2>&1
RC=$?
if [[ "$RC" -eq 1 ]]; then
	print_result "validation: rejects missing --issue" 0
else
	print_result "validation: rejects missing --issue" 1 "expected rc=1, got rc=$RC"
fi

# =============================================================================
# Test 5: unblock-on-merge — happy path with original-issue line in body
# =============================================================================
reset_stubs

# Simulate the meta-issue body containing the canonical Original line
cat >"$FIXTURE_META_BODY" <<'EOF'
## Tracking original issue

- Original: marcusquinn/aidevops#21840
- Breaker: `t2769 no_work` (`cost-circuit-breaker:no_work_loop`)
EOF

OUT=$("$META_FILER" unblock-on-merge \
	--meta 99999 --repo marcusquinn/aidevops 2>&1)
RC=$?

if [[ "$RC" -eq 0 ]]; then
	print_result "unblock: exit 0 on happy path" 0
else
	print_result "unblock: exit 0 on happy path" 1 "rc=$RC, output: $OUT"
fi

# Assert: stub gh got an issue edit --remove-label call against #21840
if grep -qE 'issue edit 21840 .* --remove-label blocked-by:#99999' "$STUB_LOG"; then
	print_result "unblock: removes blocked-by:#<meta>" 0
else
	print_result "unblock: removes blocked-by:#<meta>" 1 "stub log: $(cat "$STUB_LOG")"
fi

if grep -qE 'issue edit 21840 .*--add-label status:available' "$STUB_LOG" \
	&& ! grep -q -- '--remove-label needs-maintainer-review' "$STUB_LOG"; then
	print_result "unblock: restores status:available without clearing NMR" 0
else
	print_result "unblock: restores status:available without clearing NMR" 1 "stub log: $(cat "$STUB_LOG")"
fi

# Assert: an unblock comment was posted on #21840
if grep -qE 'issue comment 21840 ' "$STUB_LOG"; then
	print_result "unblock: posts unblock comment on original" 0
else
	print_result "unblock: posts unblock comment on original" 1 "stub log: $(cat "$STUB_LOG")"
fi

# =============================================================================
# Test 5b: unblock-on-merge — cross-repo meta unblocks original repo
# =============================================================================
reset_stubs

cat >"$FIXTURE_META_BODY" <<'EOF'
## Tracking original issue

- Original: exampleorg/examplerepo#4003
- Breaker: `t2769 no_work` (`cost-circuit-breaker:no_work_loop`)
EOF

OUT=$("$META_FILER" unblock-on-merge \
	--meta 99999 --repo marcusquinn/aidevops 2>&1)
RC=$?

if [[ "$RC" -eq 0 ]]; then
	print_result "unblock-cross-repo: exit 0" 0
else
	print_result "unblock-cross-repo: exit 0" 1 "rc=$RC, output: $OUT"
fi

if grep -qE 'issue edit 4003 --repo exampleorg/examplerepo --remove-label blocked-by:marcusquinn/aidevops#99999' "$STUB_LOG"; then
	print_result "unblock-cross-repo: removes full blocked-by label" 0
else
	print_result "unblock-cross-repo: removes full blocked-by label" 1 "stub log: $(cat "$STUB_LOG")"
fi

if grep -qE 'issue comment 4003 --repo exampleorg/examplerepo' "$STUB_LOG"; then
	print_result "unblock-cross-repo: posts comment on original repo" 0
else
	print_result "unblock-cross-repo: posts comment on original repo" 1 "stub log: $(cat "$STUB_LOG")"
fi

# =============================================================================
# Test 5c: unblock-on-merge — another current blocked-by label keeps blocked
# =============================================================================
reset_stubs
printf '1' >"$FIXTURE_BLOCKED_BY_COUNT"
cat >"$FIXTURE_META_BODY" <<'EOF'
## Tracking original issue

- Original: marcusquinn/aidevops#21840
- Breaker: `t2769 no_work` (`cost-circuit-breaker:no_work_loop`)
EOF

OUT=$("$META_FILER" unblock-on-merge \
	--meta 99999 --repo marcusquinn/aidevops 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] \
	&& ! grep -q -- '--add-label status:available' "$STUB_LOG" \
	&& ! grep -q -- '--remove-label needs-maintainer-review' "$STUB_LOG"; then
	print_result "unblock-other-blocker: preserves blocked lifecycle and NMR" 0
else
	print_result "unblock-other-blocker: preserves blocked lifecycle and NMR" 1 "rc=$RC output=$OUT stub log: $(cat "$STUB_LOG")"
fi

# =============================================================================
# Test 6: unblock-on-merge — meta-body without Original line is a no-op
# =============================================================================
reset_stubs
echo 'No tracking line here.' >"$FIXTURE_META_BODY"

"$META_FILER" unblock-on-merge \
	--meta 99999 --repo marcusquinn/aidevops >/dev/null 2>&1
RC=$?

if [[ "$RC" -eq 0 ]]; then
	print_result "unblock: silent no-op when meta has no Original line" 0
else
	print_result "unblock: silent no-op when meta has no Original line" 1 "rc=$RC"
fi

# Assert: NO issue edit on missing-Original case
if ! grep -q 'issue edit ' "$STUB_LOG"; then
	print_result "unblock: makes NO label changes when not a meta-issue" 0
else
	print_result "unblock: makes NO label changes when not a meta-issue" 1 "stub log: $(cat "$STUB_LOG")"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "Tests run: $TESTS_RUN, failed: $TESTS_FAILED"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
